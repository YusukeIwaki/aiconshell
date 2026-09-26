# frozen_string_literal: true

module Aiconshell
  module Plugins
    # Per-invocation dependencies handed to plugin handlers. env/transport/
    # clock default to the registry collaborators and can be overridden per
    # call through trusted context keys ("env", "transport", "clock").
    InvokeContext = Struct.new(:plugin_id, :operation, :input, :context,
                               :env, :transport, :clock, keyword_init: true)

    # Capability catalog + validated dispatch for in-process plugins.
    #
    #   registry = Aiconshell::Plugins::Registry.default
    #   registry.catalog
    #   registry.invoke(plugin: "github", operation: "latest_events",
    #                   input: { "scope" => "o/r" }, context: {})
    #
    # Contract:
    # - unknown plugin/operation/unsupported operation -> typed errors
    # - when context carries "scopes", the operation scope must be granted
    # - input is schema-validated before any external I/O
    # - output is schema-validated before it is returned
    class Registry
      def self.default
        @default ||= begin
          registry = new
          registry.register(Github.new)
          registry.register(Jira.new)
          registry.register(Teams.new)
          registry
        end
      end

      def initialize(env: ENV, transport: nil, clock: Time)
        @env = env
        @transport = transport || Http::NetHttpTransport.new
        @clock = clock
        @plugins = {}
      end

      def register(plugin)
        id = plugin.plugin_id.to_s
        raise ArgumentError, "plugin #{id.inspect} is already registered" if @plugins.key?(id)

        @plugins[id] = plugin
        self
      end

      # MCP-like capability catalog. Contains env variable *names* and a
      # configured flag only; values are never exposed.
      def catalog
        @plugins.values.map do |plugin|
          {
            "id" => plugin.plugin_id,
            "operations" => plugin.catalog_operations,
            "required_env" => plugin.required_env.dup,
            "configured" => !!plugin.configured?(@env)
          }
        end
      end

      # No-I/O preflight for callers that must validate a complete batch before
      # invoking any operation. Returns the normalized String-keyed input.
      def validate_input(plugin:, operation:, input:, context: {})
        validated_invocation(plugin, operation, input, context)[2]
      end

      def invoke(plugin:, operation:, input:, context: {})
        record, op, normalized, ctx_hash = validated_invocation(plugin, operation, input, context)

        invoke_ctx = InvokeContext.new(
          plugin_id: record.plugin_id,
          operation: op.name,
          input: normalized,
          context: ctx_hash,
          env: ctx_hash["env"] || ctx_hash[:env] || @env,
          transport: ctx_hash["transport"] || ctx_hash[:transport] || @transport,
          clock: ctx_hash["clock"] || ctx_hash[:clock] || @clock
        )

        output = record.call_operation(op, normalized, invoke_ctx)

        output_details = Schemas.error_details(op.output_schema, output)
        unless output_details.empty?
          raise OutputInvalid.new(plugin: record.plugin_id, operation: op.name,
                                  details: output_details)
        end

        output
      end

      private

      def validated_invocation(plugin, operation, input, context)
        record = @plugins[plugin.to_s]
        raise UnknownPlugin.new(plugin) if record.nil?

        op = record.find_operation(operation.to_s)
        raise UnknownOperation.new(plugin: record.plugin_id, operation: operation) if op.nil?
        if op.unsupported?
          raise UnsupportedOperation.new(plugin: record.plugin_id,
                                         operation: op.name, reason: op.reason)
        end

        normalized = normalize_input!(record.plugin_id, op.name, input)
        ctx_hash = context.is_a?(Hash) ? context : {}
        check_permission!(record.plugin_id, op, ctx_hash)

        details = Schemas.error_details(op.input_schema, normalized)
        unless details.empty?
          raise InputInvalid.new(plugin: record.plugin_id, operation: op.name,
                                 details: details)
        end

        record.validate_operation_input(op, normalized)
        [record, op, normalized, ctx_hash]
      end

      def normalize_input!(plugin, operation, input)
        unless input.is_a?(Hash)
          raise InputInvalid.new(plugin: plugin, operation: operation,
                                 details: ["input must be an object"])
        end

        deep_stringify_keys(input)
      rescue SystemStackError
        raise InputInvalid.new(plugin: plugin, operation: operation,
                               details: ["input is too deeply nested"])
      end

      def deep_stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), memo|
            memo[key.to_s] = deep_stringify_keys(entry)
          end
        when Array
          value.map { |entry| deep_stringify_keys(entry) }
        else
          value
        end
      end

      # Scope enforcement applies only when the trusted caller supplies a
      # scopes list; an absent list means a fully trusted internal caller.
      def check_permission!(plugin, op, ctx_hash)
        return if op.scope.nil?

        scopes = ctx_hash["scopes"] || ctx_hash[:scopes]
        return if scopes.nil?
        return if Array(scopes).map(&:to_s).include?(op.scope.to_s)

        raise PermissionDenied.new(plugin: plugin, operation: op.name,
                                   required_scope: op.scope)
      end
    end
  end
end

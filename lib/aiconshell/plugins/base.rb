# frozen_string_literal: true

require "digest"
require "json"

module Aiconshell
  module Plugins
    # Declared operation of a plugin: JSON Schemas plus the scope callers must
    # hold. Unsupported operations are listed in the catalog with a reason and
    # rejected at invoke time.
    Operation = Struct.new(:name, :input_schema, :output_schema, :scope,
                           :unsupported, :reason, :read_only, keyword_init: true) do
      def unsupported?
        !!unsupported
      end

      def read_only?
        !!read_only
      end
    end

    # Base class for in-process plugins. Subclasses declare an id, required
    # environment, and operations, then implement handle_<operation>(input, ctx)
    # private methods. All handler inputs are String-keyed Hashes that already
    # passed schema validation; outputs are validated after the handler runs.
    class Base
      class << self
        def plugin_id(value = nil)
          @plugin_id = value.to_s if value
          @plugin_id
        end

        def required_env(*names)
          @required_env = names.flatten.map(&:to_s) if names.any?
          @required_env ||= []
        end

        def operation(name, input_schema:, output_schema:, scope: nil,
                      unsupported: false, reason: nil, read_only: false)
          operations[name.to_s] = Operation.new(
            name: name.to_s,
            input_schema: input_schema,
            output_schema: output_schema,
            scope: scope&.to_s,
            unsupported: unsupported,
            reason: reason&.to_s,
            read_only: !!read_only
          )
        end

        def operations
          @operations ||= {}
        end
      end

      def plugin_id
        self.class.plugin_id
      end

      def required_env
        self.class.required_env
      end

      def find_operation(name)
        self.class.operations[name.to_s]
      end

      def catalog_operations
        self.class.operations.values.map do |op|
          entry = {
            "name" => op.name,
            "input_schema" => deep_dup(op.input_schema),
            "output_schema" => deep_dup(op.output_schema),
            "scope" => op.scope,
            "read_only" => op.read_only?
          }
          if op.unsupported?
            entry["unsupported"] = true
            entry["reason"] = op.reason
          end
          entry
        end
      end

      # Default check: every required env name is present and non-empty.
      # Adapters with alternative variables (value-or-file) override this.
      def configured?(env)
        required_env.all? { |name| present?(env[name]) }
      end

      def call_operation(op, input, invoke_ctx)
        handler = "handle_#{op.name}"
        unless respond_to?(handler, true)
          raise UnknownOperation.new(plugin: plugin_id, operation: op.name)
        end
        send(handler, input, invoke_ctx)
      end

      # Optional semantic preflight after JSON Schema validation. Implementations
      # must be pure: no credentials, transport, or mutable application state.
      # Registry#validate_input and #invoke both call this hook.
      def validate_operation_input(op, input)
      end

      protected

      def present?(value)
        !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
      end

      # Read a secret from an env variable, optionally falling back to a file
      # whose path is held in another env variable. Returns nil when missing
      # or unreadable. Never logs or echoes the value.
      def secret_from(env, name, file_name = nil)
        value = env[name]
        return value.to_s unless value.nil? || value.to_s.empty?
        return nil if file_name.nil?

        path = env[file_name]
        return nil if path.nil? || path.to_s.empty?

        File.read(path.to_s).strip
      rescue SystemCallError
        nil
      end

      def require_credentials!(missing)
        return if missing.empty?

        raise CredentialsMissing.new(plugin: plugin_id, missing: missing)
      end

      # Stable content hash distinguishing edits of the same remote object.
      def fingerprint(*parts)
        "sha256:#{Digest::SHA256.hexdigest(parts.map(&:to_s).join("\0"))}"
      end

      def utc_iso8601(time)
        time.utc.iso8601
      end

      # Normalized latest_events cursor: {} when absent. Rejects non-object
      # cursors and cursors that cannot round-trip through JSON.
      def validated_cursor(input, operation)
        cursor = input["cursor"]
        return {} if cursor.nil?

        unless cursor.is_a?(Hash)
          raise InputInvalid.new(plugin: plugin_id, operation: operation,
                                 details: ["cursor must be an object or null"])
        end
        begin
          JSON.parse(JSON.generate(cursor))
        rescue JSON::GeneratorError, JSON::ParserError
          raise InputInvalid.new(plugin: plugin_id, operation: operation,
                                 details: ["cursor must be JSON serializable"])
        end
        cursor
      end

      def deep_dup(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end

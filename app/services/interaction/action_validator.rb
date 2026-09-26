# frozen_string_literal: true

module Interaction
  # Write preflight for Coordination-proposed outbound actions (issue #11).
  # Inspects the trusted plugin catalog and registered JSON Schemas only;
  # it never invokes a plugin operation and performs no I/O. Coordination
  # validates every proposed action through here before mutating anything.
  #
  #   validator = Interaction::ActionValidator.new
  #   validator.validate(plugin: "github", operation: "reply",
  #                      input: { "resource_id" => "issue:o/r#1", "body" => "hi" })
  #
  # Failures carry only a content-free code symbol; caller text is never
  # echoed.
  class ActionValidator
    Result = Struct.new(:ok, :code, keyword_init: true) do
      def ok?
        !!ok
      end
    end

    SUPPORTED_WRITES = %w[reply create_issue send_message].freeze

    def initialize(registry: Aiconshell::Plugins::Registry.default, allowed_scopes: nil)
      @registry = registry
      @allowed_scopes_override = allowed_scopes
    end

    def validate(plugin:, operation:, input:)
      normalized = normalize_input!(input)
      entry, op = lookup_operation(plugin.to_s, operation.to_s)
      return failure(:unknown_plugin) if entry.nil?
      return failure(:unknown_operation) if op.nil?
      return failure(:unsupported_operation) if op["unsupported"] == true
      return failure(:operation_not_allowed) unless SUPPORTED_WRITES.include?(operation.to_s)
      return failure(:not_writable) if op["read_only"] == true

      unless Aiconshell::Plugins::Schemas.error_details(op["input_schema"], normalized).empty?
        return failure(:input_invalid)
      end
      return failure(:input_invalid) if normalized.fetch("body", "").to_s.strip.empty?

      destination = PluginAccess.destination(plugin.to_s, operation.to_s, normalized)
      return failure(:scope_not_allowed) unless scope_allowed?(plugin.to_s, destination)

      Result.new(ok: true, code: :ok)
    rescue SystemStackError
      failure(:input_invalid)
    end

    private

    def failure(code)
      Result.new(ok: false, code: code)
    end

    def lookup_operation(plugin, operation)
      entry = @registry.catalog.find { |item| item["id"] == plugin }
      return [nil, nil] if entry.nil?

      [entry, entry.fetch("operations", []).find { |item| item["name"] == operation }]
    end

    def normalize_input!(input)
      raise SystemStackError unless input.is_a?(Hash)

      deep_stringify_keys(input)
    end

    def deep_stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, entry), memo| memo[key.to_s] = deep_stringify_keys(entry) }
      when Array
        value.map { |entry| deep_stringify_keys(entry) }
      else
        value
      end
    end

    def current_allowed_scopes
      override = @allowed_scopes_override
      unless override.nil?
        scopes = override.respond_to?(:call) ? override.call : override
        return scopes.to_h.transform_values { |list| Array(list).map(&:to_s) }
      end

      WorkflowSettings.allowed_scopes
    end

    def scope_allowed?(plugin, scope)
      current_allowed_scopes.fetch(plugin.to_s, []).include?(scope.to_s)
    end
  end
end

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
      return failure(:input_invalid) unless input.is_a?(Hash)

      normalized = normalize_input!(input)
      # JSON Schema permits NUL, but PostgreSQL text/jsonb cannot store it.
      # Check custom nested fields and object keys before a batch is persisted.
      return failure(:input_invalid) if contains_nul?(normalized)

      entry, op = lookup_operation(plugin.to_s, operation.to_s)
      return failure(:unknown_plugin) if entry.nil?
      return failure(:unknown_operation) if op.nil?
      return failure(:unsupported_operation) if op["unsupported"] == true
      return failure(:operation_not_allowed) unless SUPPORTED_WRITES.include?(operation.to_s)
      return failure(:not_writable) unless op["read_only"] == false
      return failure(:schema_invalid) unless op["input_schema"].is_a?(Hash) && op["output_schema"].is_a?(Hash)

      unless Aiconshell::Plugins::Schemas.error_details(op["input_schema"], normalized).empty?
        return failure(:input_invalid)
      end
      return failure(:input_invalid) unless normalized["body"].is_a?(String) && normalized["body"].strip.present?
      target = normalized[operation.to_s == "reply" ? "resource_id" : "scope"]
      return failure(:input_invalid) unless target.is_a?(String) && target.strip.present?

      destination = PluginAccess.destination(plugin.to_s, operation.to_s, normalized)
      return failure(:scope_not_allowed) unless scope_allowed?(plugin.to_s, destination)

      @registry.validate_input(plugin: plugin.to_s, operation: operation.to_s, input: normalized,
        context: PluginAccess.context(plugin.to_s, operation.to_s, registry: @registry))
      Result.new(ok: true, code: :ok)
    rescue SystemStackError, Aiconshell::Plugins::InputInvalid
      failure(:input_invalid)
    rescue Aiconshell::Plugins::PermissionDenied
      failure(:permission_denied)
    rescue StandardError
      failure(:validation_failed)
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
      deep_stringify_keys(input)
    end

    def contains_nul?(value)
      case value
      when String then value.include?("\u0000")
      when Hash then value.any? { |key, entry| contains_nul?(key) || contains_nul?(entry) }
      when Array then value.any? { |entry| contains_nul?(entry) }
      else false
      end
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

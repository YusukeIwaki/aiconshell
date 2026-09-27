# frozen_string_literal: true

require "json"
require_relative "plugin_access"
require_relative "oauth_context" unless defined?(Interaction::OauthContext)

module Interaction
  # Sole safe on-demand read path from Coordination to plugin operations.
  # Only declared read_only operations are allowed. Inputs and outputs use
  # the exact registered JSON Schemas, destinations require the operator
  # AICONSHELL_ALLOWED_SCOPES allowlist, and capability scopes come from
  # PluginAccess.context. No IntegrationCursor or ExternalEvent writes.
  #
  #   service = Interaction::QueryService.new
  #   service.validate(plugin: "github", operation: "list_issues",
  #                    input: { "scope" => "owner/repo" })
  #   service.call(plugin: "github", operation: "list_issues",
  #                input: { "scope" => "owner/repo" })
  #
  # Results carry only a content-free code symbol on failure; upstream text
  # is never echoed. Serialized output is bounded by MAX_OUTPUT_BYTES.
  class QueryService
    Result = Struct.new(:ok, :code, :data, keyword_init: true) do
      def ok?
        !!ok
      end
    end

    MAX_OUTPUT_BYTES = 128_000

    def initialize(registry: Aiconshell::Plugins::Registry.default,
                   event_sink: WorkflowEvents, allowed_scopes: nil,
                   oauth_credential_provider: nil)
      @registry = registry
      @event_sink = event_sink
      @allowed_scopes_override = allowed_scopes
      @oauth_credential_provider = oauth_credential_provider
    end

    # Trusted binding snapshot for an OAuth read. The AI never supplies
    # this; the application fixes it just-in-time and fences the result.
    def oauth_snapshot(plugin)
      return nil unless OauthContext.oauth_plugin?(plugin.to_s)

      provider = oauth_provider
      raise ArgumentError, "oauth credential provider is required" if provider.nil?

      OauthContext.snapshot_binding(plugin.to_s, credential_provider: provider)
    end

    def oauth_binding_current?(snapshot, plugin)
      OauthContext.snapshot_current?(snapshot, plugin.to_s, credential_provider: oauth_provider)
    end

    # Full capability catalog (env names + configured flags only, no values).
    def catalog
      @registry.catalog
    end

    # Read-only operations only, for Coordination prompts (no credentials).
    def read_only_catalog
      catalog.map do |entry|
        entry.merge("operations" => entry.fetch("operations", []).select { |op| op["read_only"] == true })
      end
    end

    # Operator-allowlisted destinations, without credentials.
    def allowed_targets(plugin = nil)
      scopes = current_allowed_scopes
      return scopes.transform_values(&:dup) if plugin.nil?

      scopes.fetch(plugin.to_s, []).dup
    end

    # Preflight without I/O: unknown/unsupported/non-read_only operations,
    # input schema violations, and disallowed destinations fail here with no
    # transport request. Registry preflight includes the plugin's pure semantic
    # validation (for example repository-bound query cursors).
    def validate(plugin:, operation:, input:)
      return failure(:input_invalid) unless input.is_a?(Hash)

      normalized = normalize_input!(input)
      entry, op = lookup_operation(plugin.to_s, operation.to_s)
      return failure(:unknown_plugin) if entry.nil?
      return failure(:unknown_operation) if op.nil?
      return failure(:unsupported_operation) if op["unsupported"] == true
      return failure(:not_read_only) unless op["read_only"] == true
      return failure(:schema_invalid) unless op["input_schema"].is_a?(Hash) && op["output_schema"].is_a?(Hash)

      unless Aiconshell::Plugins::Schemas.error_details(op["input_schema"], normalized).empty?
        return failure(:input_invalid)
      end

      destination = PluginAccess.destination(plugin.to_s, operation.to_s, normalized)
      return failure(:scope_not_allowed) unless scope_allowed?(plugin.to_s, destination)

      @registry.validate_input(plugin: plugin.to_s, operation: operation.to_s, input: normalized,
        context: PluginAccess.context(plugin.to_s, operation.to_s, registry: @registry))
      Result.new(ok: true, code: :ok, data: nil)
    rescue SystemStackError, Aiconshell::Plugins::InputInvalid
      failure(:input_invalid)
    rescue Aiconshell::Plugins::PermissionDenied
      failure(:permission_denied)
    rescue StandardError
      failure(:internal_error)
    end

    # Repeats validation, then invokes the plugin once. Output is validated
    # by the registry against the registered schema and bounded by serialized
    # bytes. Failures never include upstream text. OAuth reads fix the
    # trusted binding before HTTP and fence it after: a replacement in
    # between fails instead of returning another principal's data.
    # An explicit `binding:` fixes the snapshot for read→result fencing;
    # otherwise a fresh snapshot is taken here.
    def call(plugin:, operation:, input:, binding: nil)
      preflight = validate(plugin: plugin, operation: operation, input: input)
      unless preflight.ok?
        emit(preflight.code, plugin: plugin.to_s, operation: operation.to_s)
        return preflight
      end

      snapshot = nil
      if OauthContext.oauth_plugin?(plugin.to_s)
        begin
          snapshot = binding.nil? ? oauth_snapshot(plugin.to_s) : binding
        rescue StandardError => error
          name = error.class.name.to_s
          if name.match?(/NotConnected/) || name.match?(/Oauth.*Error|BindingMismatch|ProviderError/)
            emit(:not_connected, plugin: plugin.to_s, operation: operation.to_s)
            return failure(:not_connected)
          elsif error.is_a?(ArgumentError)
            emit(:credentials_missing, plugin: plugin.to_s, operation: operation.to_s)
            return failure(:credentials_missing)
          else
            emit(:credentials_missing, plugin: plugin.to_s, operation: operation.to_s)
            return failure(:credentials_missing)
          end
        end
      end

      normalized = normalize_input!(input)
      context = if OauthContext.oauth_plugin?(plugin.to_s)
        PluginAccess.context(plugin.to_s, operation.to_s, registry: @registry).merge(
          "oauth_binding" => snapshot, "oauth_credential_provider" => oauth_provider
        )
      else
        PluginAccess.context(plugin.to_s, operation.to_s, registry: @registry)
      end
      output = @registry.invoke(
        plugin: plugin.to_s, operation: operation.to_s, input: normalized,
        context: context
      )
      if OauthContext.oauth_plugin?(plugin.to_s) && !oauth_binding_current?(snapshot, plugin.to_s)
        emit(:stale_binding, plugin: plugin.to_s, operation: operation.to_s)
        return failure(:stale_binding)
      end
      bytes = begin
        JSON.generate(output).bytesize
      rescue JSON::GeneratorError
        emit(:output_invalid, plugin: plugin.to_s, operation: operation.to_s)
        return failure(:output_invalid)
      end
      if bytes > MAX_OUTPUT_BYTES
        emit(:output_too_large, plugin: plugin.to_s, operation: operation.to_s)
        return failure(:output_too_large)
      end

      emit(:ok, plugin: plugin.to_s, operation: operation.to_s)
      Result.new(ok: true, code: :ok, data: output)
    rescue SystemStackError
      emit(:input_invalid, plugin: plugin.to_s, operation: operation.to_s)
      failure(:input_invalid)
    rescue Aiconshell::Plugins::UnknownPlugin
      emit(:unknown_plugin, plugin: plugin.to_s, operation: operation.to_s)
      failure(:unknown_plugin)
    rescue Aiconshell::Plugins::UnsupportedOperation
      emit(:unsupported_operation, plugin: plugin.to_s, operation: operation.to_s)
      failure(:unsupported_operation)
    rescue Aiconshell::Plugins::UnknownOperation
      emit(:unknown_operation, plugin: plugin.to_s, operation: operation.to_s)
      failure(:unknown_operation)
    rescue Aiconshell::Plugins::InputInvalid
      emit(:input_invalid, plugin: plugin.to_s, operation: operation.to_s)
      failure(:input_invalid)
    rescue Aiconshell::Plugins::PermissionDenied
      emit(:permission_denied, plugin: plugin.to_s, operation: operation.to_s)
      failure(:permission_denied)
    rescue Aiconshell::Plugins::CredentialsMissing
      emit(:credentials_missing, plugin: plugin.to_s, operation: operation.to_s)
      failure(:credentials_missing)
    rescue Aiconshell::Plugins::HostRejected
      emit(:host_rejected, plugin: plugin.to_s, operation: operation.to_s)
      failure(:host_rejected)
    rescue Aiconshell::Plugins::RateLimited
      emit(:rate_limited, plugin: plugin.to_s, operation: operation.to_s)
      failure(:rate_limited)
    rescue Aiconshell::Plugins::OutputInvalid
      emit(:output_invalid, plugin: plugin.to_s, operation: operation.to_s)
      failure(:output_invalid)
    rescue Aiconshell::Plugins::IncompletePoll
      emit(:incomplete_poll, plugin: plugin.to_s, operation: operation.to_s)
      failure(:incomplete_poll)
    rescue Aiconshell::Plugins::HttpError, Aiconshell::Plugins::TransportError,
           Aiconshell::Plugins::TransportTimeout
      emit(:upstream_error, plugin: plugin.to_s, operation: operation.to_s)
      failure(:upstream_error)
    rescue StandardError => error
      if (code = oauth_failure_code(error))
        emit(code, plugin: plugin.to_s, operation: operation.to_s)
        failure(code)
      else
        emit(:internal_error, plugin: plugin.to_s, operation: operation.to_s)
        failure(:internal_error)
      end
    end

    private

    def failure(code)
      Result.new(ok: false, code: code, data: nil)
    end

    def lookup_operation(plugin, operation)
      entry = catalog.find { |item| item["id"] == plugin }
      return [nil, nil] if entry.nil?

      [entry, entry.fetch("operations", []).find { |item| item["name"] == operation }]
    end

    def normalize_input!(input)
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

    def oauth_provider
      return @oauth_credential_provider unless @oauth_credential_provider.nil?
      return nil unless defined?(::Oauth::CredentialProvider)

      @oauth_credential_provider ||= begin
        ::Oauth::CredentialProvider.new(event_sink: @event_sink)
      rescue StandardError
        nil
      end
    end

    # Class-name based so standalone plugin unit tests (without the Rails
    # Oauth lane loaded) still classify OAuth failures without constants.
    def oauth_failure_code(error)
      name = error.class.name.to_s
      return :not_connected if name.match?(/NotConnected/)
      return :stale_binding if name.match?(/BindingMismatch/)
      return :refresh_busy if name.match?(/RefreshBusy/)
      if name.match?(/ProviderError/)
        code = error.respond_to?(:code) ? error.code.to_s : ""
        return code == "invalid_grant" ? :not_connected : :upstream_error
      end

      nil
    rescue StandardError
      nil
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

    def emit(code, plugin:, operation:)
      return if @event_sink.nil?

      entry, op = lookup_operation(plugin, operation)
      @event_sink.emit(layer: "interaction",
                       kind: code == :ok ? "query.completed" : "query.failed",
                       message: "Query #{code}",
                       data: { plugin: entry ? entry.fetch("id") : "unknown",
                               operation: op ? op.fetch("name") : "unknown", code: code.to_s })
    rescue StandardError
      nil
    end
  end
end

# frozen_string_literal: true

module Interaction
  # Trusted OAuth binding snapshots for delegated plugins (issue #26).
  #
  # The application (never the user/AI) fixes connection id, generation,
  # principal, tenant/cloud as a secret-free snapshot and passes it with
  # the credential provider in the plugin invoke context. Adapters resolve
  # the same binding to an access token just-in-time; they never re-select
  # the "current" binding and never fall back to service-account
  # credentials. Binding/provider values never enter AI input/output JSON.
  module OauthContext
    module_function

    def oauth_plugin?(plugin)
      PluginAccess.oauth_plugin?(plugin)
    end

    def provider_name(plugin)
      PluginAccess.oauth_provider_name(plugin)
    end

    # Secret-free snapshot for an OAuth plugin, or nil for legacy plugins.
    # Raises the provider's typed NotConnected (with a safe code) when the
    # OAuth connection is unconfigured or unusable, before any external I/O.
    def snapshot_binding(plugin, credential_provider:)
      name = provider_name(plugin)
      return nil if name.nil?
      raise ArgumentError, "oauth credential provider is required" if credential_provider.nil?

      binding = credential_provider.binding_for(name)
      binding.is_a?(Hash) ? binding : binding.to_h
    end

    # Trusted invoke context for poll/query/outbound: capability scopes
    # plus the fixed binding and provider for OAuth plugins. Legacy
    # plugins receive scopes only.
    def invoke_context(plugin, operation, registry:, credential_provider: nil, binding: nil)
      base = PluginAccess.context(plugin, operation, registry: registry)
      return base unless oauth_plugin?(plugin)

      resolved = binding || snapshot_binding(plugin, credential_provider: credential_provider)
      base.merge("oauth_binding" => resolved, "oauth_credential_provider" => credential_provider)
    end

    # True when a previously fixed snapshot still matches the current
    # stored connection. Any disconnect/replacement (generation, principal,
    # tenant/cloud, connection id) fails closed before further writes.
    def snapshot_current?(snapshot, plugin, credential_provider:)
      return true unless oauth_plugin?(plugin)
      return false if snapshot.nil? || credential_provider.nil?

      current = credential_provider.binding_for(provider_name(plugin))
      current_hash = current.is_a?(Hash) ? current : current.to_h
      bound = Aiconshell::Oauth::Binding.from_h(snapshot)
      bound.matches?(current_hash)
    rescue StandardError
      false
    end

    def binding_display(binding)
      hash = binding.is_a?(Hash) ? binding : binding.to_h
      {
        "provider" => hash["provider"] || hash[:provider],
        "generation" => hash["generation"] || hash[:generation],
        "connection_id" => hash["connection_id"] || hash[:connection_id]
      }
    end
  end
end

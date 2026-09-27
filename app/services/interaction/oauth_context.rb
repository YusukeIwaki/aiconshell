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

    # Generation-scoped source key for OAuth Task isolation (issue #26).
    # Provider raw IDs stay unchanged; this key scopes the Task join (and
    # its DB uniqueness) per fetching connection generation plus provider
    # resource space (provider plus fixed tenant/cloud), so a new post or
    # edit fetched after a reconnect becomes current-generation work
    # without joining the old generation's Task. Legacy plugins always
    # return nil and keep global dedup. OAuth plugins with a missing/blank
    # binding also return nil (fail open toward the legacy global path;
    # polls fence missing bindings before persisting).
    def source_key_for(plugin, binding)
      return nil unless oauth_plugin?(plugin.to_s)
      return nil unless binding.is_a?(Hash)

      get = ->(key) do
        value = binding[key.to_s]
        value = binding[key.to_sym] if value.nil?
        value
      end
      provider = get.call("provider").to_s
      return nil if provider.empty?

      connection_id = get.call("connection_id").to_s
      generation = get.call("generation").to_s
      return nil if connection_id.empty? || generation.empty?

      [provider, get.call("tenant").to_s, get.call("cloud").to_s,
       connection_id, generation, get.call("principal").to_s].join("\u001F")
    end

    # Generation-independent event identity for OAuth inbox dedup
    # (issue #26). The same external object revision re-fetched after a
    # reconnect is already-handled work, not a new Task: dedup, snapshot
    # watermarks, and poll serialization locks all scope by provider
    # resource space (provider plus fixed tenant/cloud) with the raw
    # provider IDs unchanged. A different cloud/tenant with the same
    # numeric IDs is a distinct space and stays ingestible. Task joins
    # and reply permission stay generation-pinned via `source_key_for`
    # above; legacy plugins always return nil and keep global dedup.
    def event_space_key_for(plugin, binding)
      return nil unless oauth_plugin?(plugin.to_s)
      return nil unless binding.is_a?(Hash)

      get = ->(key) do
        value = binding[key.to_s]
        value = binding[key.to_sym] if value.nil?
        value
      end
      provider = get.call("provider").to_s
      return nil if provider.empty?

      [provider, get.call("tenant").to_s, get.call("cloud").to_s].join("\u001F")
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

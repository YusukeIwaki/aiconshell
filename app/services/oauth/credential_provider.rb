# frozen_string_literal: true

# Explicit full root (no defined? guard): a pre-defined Binding never
# implies the whole entry (State, Pkce, TokenSet, SecretBox, PROVIDERS) is
# loaded.
require "aiconshell/oauth"

module Oauth
  # Public credential contract for later lanes (issues #24/#25/#26).
  # Plugins never receive tokens in their input: they receive the
  # secret-free binding, and the trusted application side resolves it to
  # an access token just-in-time before the external write through this
  # provider. The same binding never yields another connection's token;
  # replaced or disconnected connections reject before any external call.
  #
  # Tokens resolved here must never be placed into plugin input, AI
  # prompts/outputs, logs, or EventLog data.
  class CredentialProvider
    class NotConnected < Aiconshell::Oauth::Error
    end

    def initialize(env: ENV, transport: nil, clock: Time,
                   secret_store: nil, event_sink: WorkflowEvents)
      @config = Aiconshell::Oauth::Config.new(env: env)
      @tokens = TokenService.new(
        env: env, transport: transport, clock: clock,
        secret_store: secret_store, event_sink: event_sink
      )
    end

    # Current secret-free binding for a connected provider. Raises
    # NotConnected when the provider is unconfigured or has no usable
    # connection; the caller shows the safe status instead.
    def binding_for(provider)
      name = provider.to_s
      unless %w[atlassian microsoft].include?(name)
        raise NotConnected.new("provider_error", "unknown oauth provider")
      end
      if @config.missing_env_names(name).any?
        raise NotConnected.new("unconfigured", "oauth #{name} is not configured")
      end

      row = OauthConnection.find_by(provider: name)
      if row.nil? || !row.connected?
        raise NotConnected.new(row&.error_code == "invalid_grant" ? "invalid_grant" : "not_connected")
      end

      Aiconshell::Oauth::Binding.new(
        connection_id: row.id,
        generation: row.generation,
        provider: row.provider,
        principal: row.external_principal.to_s,
        tenant: row.tenant_id,
        cloud: row.cloud_id
      )
    end

    # Resolves a binding to its access token, or raises BindingMismatch /
    # NotConnected / refresh classifications. The token String is returned
    # to the trusted caller only and must not be persisted elsewhere.
    def access_token(binding)
      @tokens.fetch(binding)
    rescue Aiconshell::Oauth::BindingMismatch
      raise
    rescue Aiconshell::Oauth::RefreshBusy
      raise
    rescue Aiconshell::Oauth::ProviderError => e
      raise NotConnected.new(e.code, e.message) if e.code == "invalid_grant"

      raise
    end

    def configured?(provider)
      @config.missing_env_names(provider.to_s).empty?
    end

    def inspect
      "#<Oauth::CredentialProvider>"
    end

    def to_s
      inspect
    end
  end
end

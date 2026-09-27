# frozen_string_literal: true

require "securerandom"
# Explicit full roots (no defined? guards): a single pre-defined constant
# (Atlassian, Binding, ...) never implies the whole entry (State, Pkce,
# TokenSet, SecretBox, PROVIDERS, all adapters) is loaded.
require "aiconshell/oauth"
require "aiconshell/plugins"

module Oauth
  # Just-in-time access tokens for a secret-free binding (issue #22).
  # A valid unexpired token is reused; an expiring one is refreshed before
  # use. Refresh token rotation is atomic, concurrent refreshes are
  # serialized by an exclusive lease with generation fencing, and no DB
  # transaction or row lock is held across network calls: the lease is
  # claimed, the network runs lock-free, then the result is committed only
  # when the lease is still valid and the generation is unchanged. A stale
  # result (expired lease, replaced or disconnected connection) is
  # discarded and never resurrects the connection.
  #
  # Rotation uncertainty: when the provider has accepted the rotation but
  # the response never arrives (timeout) or the commit never lands (DB
  # failure/crash), the old refresh token may already be dead. This
  # service never asserts the old token is still valid: a timeout keeps
  # the old row (the next refresh proves it), and only an explicit
  # invalid_grant moves the connection to needs_reauth. An uncertain
  # result never overwrites a newer connection or a disconnect.
  class TokenService
    REFRESH_SKEW_SECONDS = 120
    REFRESH_LEASE_SECONDS = 120

    def initialize(env: ENV, transport: nil, clock: Time,
                   secret_store: nil, event_sink: WorkflowEvents)
      @config = Aiconshell::Oauth::Config.new(env: env)
      @transport = transport || Aiconshell::Plugins::Http::NetHttpTransport.new
      @clock = clock
      @secret_store = secret_store || SecretStore.default
      @event_sink = event_sink
    end

    def inspect
      "#<Oauth::TokenService>"
    end

    def to_s
      inspect
    end

    # Returns the access token String for a binding Hash or Binding (see
    # Aiconshell::Oauth::Binding). Raises BindingMismatch before any
    # external I/O when the binding no longer matches the stored
    # connection, when the fixed client/cloud/tenant moved since connect,
    # or when the lease/generation is stale; raises RefreshBusy when
    # another refresh holds the lease. A still-valid token is never issued
    # after a configuration change, and an expired token never triggers a
    # refresh HTTP under a changed configuration.
    def fetch(binding)
      bound = Aiconshell::Oauth::Binding.from_h(binding)
      connection = OauthConnection.find_by(id: bound.connection_id)
      raise Aiconshell::Oauth::BindingMismatch.new if connection.nil?
      unless bound.matches?(connection.binding_snapshot)
        raise Aiconshell::Oauth::BindingMismatch.new
      end
      unless connection.connected?
        raise Aiconshell::Oauth::ProviderError.new(connection.error_code || "provider_error")
      end
      unless config_matches_connection?(connection)
        raise Aiconshell::Oauth::BindingMismatch.new
      end

      now_time = now
      if connection.token_expires_at && connection.token_expires_at - REFRESH_SKEW_SECONDS > now_time
        token = @secret_store.decrypt(connection.encrypted_access_token)
        raise Aiconshell::Oauth::ProviderError.new("unexpected_response") unless token.is_a?(String) && !token.empty?

        return token
      end

      refresh_with_lease!(connection, bound)
    end

    private

    # Claim an exclusive lease under a short row lock, run the provider
    # refresh lock-free, then commit only when the lease and generation
    # still hold.
    def refresh_with_lease!(connection, bound)
      claim = claim_lease!(connection, bound)
      lease_token = claim[:lease_token]
      refresh_plaintext = claim[:refresh_plaintext]
      provider_name = claim[:provider]

      rotated = nil
      begin
        rotated = provider_module(provider_name).refresh(
          transport: @transport, config: @config, refresh_token: refresh_plaintext
        )
      rescue Aiconshell::Oauth::ProviderError => e
        if e.code == "invalid_grant"
          revoke_for_reauth!(connection.id, lease_token)
        else
          release_lease!(connection.id, lease_token)
        end
        raise
      rescue StandardError
        release_lease!(connection.id, lease_token)
        raise Aiconshell::Oauth::ProviderError.new("provider_error")
      end

      commit_rotation!(connection.id, lease_token, rotated)
    end

    def provider_module(name)
      case name.to_s
      when "atlassian" then Aiconshell::Oauth::Atlassian
      when "microsoft" then Aiconshell::Oauth::Microsoft
      else raise Aiconshell::Oauth::ProviderError.new("provider_error")
      end
    end

    # Claims the exclusive lease. A missing/undecryptable refresh token
    # moves the connection to needs_reauth in a committed write: the
    # update is committed before raising so it is never rolled back.
    # The fixed client/cloud/tenant is rechecked under the row lock with a
    # fresh clock before any HTTP, so a changed configuration never sends
    # the old refresh token externally. Shares the provider advisory lock
    # order with publish/disconnect and never spans the network.
    def claim_lease!(connection, bound)
      claimed = nil
      needs_reauth_row = nil
      OauthConnection.transaction do
        advisory_lock!(connection.provider)
        row = OauthConnection.lock.find_by(id: connection.id)
        raise Aiconshell::Oauth::BindingMismatch.new if row.nil?
        unless bound.matches?(row.binding_snapshot)
          raise Aiconshell::Oauth::BindingMismatch.new
        end
        unless row.connected?
          raise Aiconshell::Oauth::ProviderError.new(row.error_code || "provider_error")
        end
        fresh_now = now
        unless config_matches_connection?(row)
          raise Aiconshell::Oauth::BindingMismatch.new
        end
        if row.refresh_lease_held?(fresh_now)
          raise Aiconshell::Oauth::RefreshBusy.new
        end

        refresh_plaintext = @secret_store.decrypt(row.encrypted_refresh_token)
        if refresh_plaintext.nil? || !refresh_plaintext.is_a?(String) || refresh_plaintext.empty?
          row.update!(state: "needs_reauth", error_code: "invalid_grant")
          needs_reauth_row = row
          next
        end

        token = SecureRandom.uuid
        row.update!(
          refresh_lease_token: token,
          refresh_lease_expires_at: fresh_now + REFRESH_LEASE_SECONDS,
          refresh_lease_generation: row.generation
        )
        claimed = { lease_token: token, refresh_plaintext: refresh_plaintext, provider: row.provider }
      end
      if needs_reauth_row
        emit_needs_reauth(needs_reauth_row)
        raise Aiconshell::Oauth::ProviderError.new("invalid_grant")
      end
      claimed
    end

    # The refresh token was rejected: the connection needs a reconnect.
    # Committed only when our lease still owns the row and the generation
    # is unchanged; otherwise the newer state wins and this result dies.
    # Lease clocks are read fresh after the locks are held.
    def revoke_for_reauth!(connection_id, lease_token)
      provider_name = OauthConnection.where(id: connection_id).pick(:provider) || "unknown"
      OauthConnection.transaction do
        advisory_lock!(provider_name) unless provider_name == "unknown"
        row = OauthConnection.lock.find_by(id: connection_id)
        next if row.nil? || row.refresh_lease_token != lease_token

        now_time = now
        if row.refresh_lease_expires_at && row.refresh_lease_expires_at <= now_time
          row.update!(
            refresh_lease_token: nil, refresh_lease_expires_at: nil,
            refresh_lease_generation: nil
          )
          next
        end
        next unless row.refresh_lease_generation == row.generation

        row.update!(
          state: "needs_reauth",
          error_code: "invalid_grant",
          encrypted_access_token: nil,
          encrypted_refresh_token: nil,
          token_expires_at: nil,
          refresh_lease_token: nil,
          refresh_lease_expires_at: nil,
          refresh_lease_generation: nil
        )
        emit_needs_reauth(row)
      end
      nil
    end

    def release_lease!(connection_id, lease_token)
      provider_name = OauthConnection.where(id: connection_id).pick(:provider)
      OauthConnection.transaction do
        advisory_lock!(provider_name) if provider_name
        row = OauthConnection.lock.find_by(id: connection_id)
        next if row.nil? || row.refresh_lease_token != lease_token

        row.update!(
          refresh_lease_token: nil,
          refresh_lease_expires_at: nil,
          refresh_lease_generation: nil
        )
      end
      nil
    rescue StandardError
      nil
    end

    # Atomic rotation: new tokens land in one write, the lease clears, and
    # the generation is untouched (a refresh is not a replacement). Stale
    # results from an expired lease or a replaced/disconnected connection
    # are discarded instead of resurrecting anything. An explicit scope
    # narrowing or a client/tenant/cloud change since connect is never
    # issued as a normal token to the old verified binding. An omitted
    # scope (nil, per the Entra spec) keeps the stored scopes.
    # Lease-expiry clears are committed before raising so they persist.
    def commit_rotation!(connection_id, lease_token, rotated)
      encrypted_access = @secret_store.encrypt(rotated["access_token"])
      rotated_scope = rotated["scope"]
      rotated_refresh_raw = rotated["refresh_token"]

      provider_name = OauthConnection.where(id: connection_id).pick(:provider)
      outcome = nil
      token = nil
      OauthConnection.transaction do
        advisory_lock!(provider_name) if provider_name
        row = OauthConnection.lock.find_by(id: connection_id)
        fresh_now = now
        if row.nil?
          outcome = :binding_mismatch
          next
        end
        if row.refresh_lease_token != lease_token
          outcome = :stale_lease
          next
        end
        if row.refresh_lease_expires_at && row.refresh_lease_expires_at <= fresh_now
          row.update!(
            refresh_lease_token: nil, refresh_lease_expires_at: nil,
            refresh_lease_generation: nil
          )
          outcome = :expired
          next
        end
        if row.refresh_lease_generation != row.generation
          outcome = :binding_mismatch
          next
        end
        unless row.connected?
          outcome = [:provider_error, (row.error_code || "provider_error")]
          next
        end
        unless config_matches_connection?(row)
          row.update!(
            refresh_lease_token: nil, refresh_lease_expires_at: nil,
            refresh_lease_generation: nil
          )
          outcome = :binding_mismatch
          next
        end
        unless rotated_scope.nil? || rotated_scope.is_a?(String)
          row.update!(
            refresh_lease_token: nil, refresh_lease_expires_at: nil,
            refresh_lease_generation: nil
          )
          outcome = [:provider_error, "unexpected_response"]
          next
        end
        if !rotated_scope.nil? && !delegated_scopes_covered?(row.provider, rotated_scope)
          row.update!(
            refresh_lease_token: nil, refresh_lease_expires_at: nil,
            refresh_lease_generation: nil
          )
          outcome = [:provider_error, "scope_mismatch"]
          next
        end

        previous_refresh = @secret_store.decrypt(row.encrypted_refresh_token)
        new_refresh_ciphertext = if rotated_refresh_raw.is_a?(String) && !rotated_refresh_raw.empty?
          @secret_store.encrypt(rotated_refresh_raw)
        elsif previous_refresh.is_a?(String) && !previous_refresh.empty?
          row.encrypted_refresh_token
        else
          row.encrypted_refresh_token
        end
        new_scopes = rotated_scope.nil? ? row.granted_scopes.to_s : Aiconshell::Oauth::TokenSet.scope_list(rotated_scope).join(" ")
        row.update!(
          encrypted_access_token: encrypted_access,
          encrypted_refresh_token: new_refresh_ciphertext,
          token_expires_at: fresh_now + rotated["expires_in"].to_i,
          granted_scopes: new_scopes,
          refresh_lease_token: nil,
          refresh_lease_expires_at: nil,
          refresh_lease_generation: nil
        )
        token = rotated["access_token"]
        outcome = :ok
      end

      case outcome
      when :ok then token
      when :stale_lease then raise Aiconshell::Oauth::BindingMismatch.new
      when :expired then raise Aiconshell::Oauth::ProviderError.new("expired")
      when :binding_mismatch then raise Aiconshell::Oauth::BindingMismatch.new
      when Array
        _, code = outcome
        raise Aiconshell::Oauth::ProviderError.new(code)
      else
        raise Aiconshell::Oauth::ProviderError.new("provider_error")
      end
    end

    def advisory_lock!(provider_name)
      return if provider_name.nil? || provider_name.to_s.empty?

      key = "aiconshell:oauth:#{provider_name}"
      quoted = OauthConnection.connection.quote(key)
      OauthConnection.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtext(#{quoted}))"
      )
    end

    def config_matches_connection?(row)
      current = @config.provider(row.provider)
      if row.client_id && !row.client_id.to_s.empty? && row.client_id.to_s != current.client_id.to_s
        return false
      end
      if row.provider == "atlassian"
        return false if row.cloud_id.to_s != current.cloud_id.to_s
      else
        return false if row.tenant_id.to_s != current.tenant_id.to_s
        return false if @config.forbidden_tenant?(current.tenant_id.to_s)
      end
      true
    rescue Aiconshell::Oauth::Error
      false
    end

    def delegated_scopes_covered?(provider, scope_text)
      required = provider.to_s == "atlassian" ? Aiconshell::Oauth::Config::ATLASSIAN_DELEGATED_SCOPES : Aiconshell::Oauth::Config::MICROSOFT_DELEGATED_SCOPES
      Aiconshell::Oauth::TokenSet.granted_scopes?(scope_text, required)
    end

    def emit_needs_reauth(row)
      @event_sink.emit(
        layer: "interaction", kind: "oauth.needs_reauth", message: "OAuth #{row.provider} needs reconnect",
        data: { "provider" => row.provider.to_s, "status" => "needs_reauth", "error_code" => "invalid_grant" }
      )
    rescue StandardError
      nil
    end

    def now
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end

# frozen_string_literal: true

require "securerandom"
require "aiconshell/oauth" unless defined?(Aiconshell::Oauth::Atlassian)
require "aiconshell/plugins" unless defined?(Aiconshell::Plugins::Registry)

module Oauth
  # Operator-facing OAuth connect/disconnect orchestration (issue #22).
  # Controllers (issue #23) hand an intent here; this service persists the
  # short-lived auth attempt and the worker-confirmed connection row.
  # Business Task/TaskRun, LayerPolicy, and the shared plugin Registry are
  # never touched.
  #
  # All external boundaries are injected: env, transport, clock,
  # secret_store, event_sink. The token endpoint, redirect URI, and tenant
  # always come from fixed configuration; callback input carries only
  # state, code, and error.
  class AuthService
    class InvalidRequest < Aiconshell::Oauth::Error
    end

    ATTEMPT_TTL_SECONDS = 600

    def initialize(env: ENV, transport: nil, clock: Time,
                   secret_store: nil, event_sink: WorkflowEvents)
      @config = Aiconshell::Oauth::Config.new(env: env)
      @transport = transport || Aiconshell::Plugins::Http::NetHttpTransport.new
      @clock = clock
      @secret_store = secret_store || SecretStore.default
      @event_sink = event_sink
    end

    def inspect
      "#<Oauth::AuthService>"
    end

    def to_s
      inspect
    end

    # Starts one authorization attempt. Returns a Hash with the attempt id,
    # the fixed provider authorize URL, the one-time raw state, and expiry.
    # The raw state is returned here exactly once and never persisted.
    # The fixed client/redirect/cloud/tenant/scopes snapshot is stored with
    # the attempt so a later configuration change cannot complete it.
    def begin(provider:, browser_session_id:)
      name = provider.to_s
      provider_module(name)
      session = session_text(browser_session_id)
      ensure_configured!(name)

      provider_config = @config.provider(name)
      connection_generation = OauthConnection.where(provider: name).pick(:generation) || 0
      state = Aiconshell::Oauth::State.generate
      session_digest = Aiconshell::Oauth::State.digest_session(session)

      verifier_ciphertext = nil
      url = nil
      if name == "microsoft"
        pkce = Aiconshell::Oauth::Pkce.generate
        verifier_ciphertext = @secret_store.encrypt(pkce[:verifier])
        url = Aiconshell::Oauth::Microsoft.authorize_url(
          config: @config, state: state[:raw], challenge: pkce[:challenge]
        )
      else
        url = Aiconshell::Oauth::Atlassian.authorize_url(config: @config, state: state[:raw])
      end

      attempt = nil
      3.times do
        begin
          attempt = OauthAuthAttempt.create!(
            provider: name,
            state_digest: state[:digest],
            browser_session_digest: session_digest,
            redirect_uri: provider_config.redirect_uri.to_s,
            client_id: provider_config.client_id.to_s,
            cloud_id: provider_config.cloud_id,
            tenant_id: provider_config.tenant_id,
            scopes: provider_config.scopes.join(" "),
            encrypted_code_verifier: verifier_ciphertext,
            generation_at_start: connection_generation,
            status: "pending",
            expires_at: now + ATTEMPT_TTL_SECONDS
          )
          break
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
          raise e unless duplicate_state_digest?(e)

          state = Aiconshell::Oauth::State.generate
          attempt = nil
        end
      end
      raise InvalidRequest.new("provider_error", "could not start authorization") if attempt.nil?

      emit("oauth.authorize_started", name, { "status" => "pending" })
      {
        "attempt_id" => attempt.id,
        "authorize_url" => url,
        "state" => state[:raw],
        "expires_at" => attempt.expires_at
      }
    end

    # Completes the provider callback. On success returns the connected
    # OauthConnection (generation bumped, including the first connection).
    # On any failure raises a typed error carrying only the safe code; a
    # previously healthy connection is never modified by a failed callback.
    def callback(provider:, state:, code:, browser_session_id:, error: nil)
      name = provider.to_s
      provider_module(name)
      raw_state = state.to_s
      raise InvalidRequest.new("state_mismatch", "state is missing") if raw_state.empty?

      session = session_text(browser_session_id)
      attempt = OauthAuthAttempt.find_by(state_digest: Aiconshell::Oauth::State.digest(raw_state))
      raise Aiconshell::Oauth::StateInvalid.new("state_mismatch") if attempt.nil?
      raise Aiconshell::Oauth::StateInvalid.new("state_mismatch") if attempt.provider != name
      unless attempt.browser_session_digest == Aiconshell::Oauth::State.digest_session(session)
        raise Aiconshell::Oauth::StateInvalid.new("state_mismatch")
      end
      if attempt.expired_due?(now)
        fail_attempt(attempt, "expired")
        raise Aiconshell::Oauth::StateInvalid.new("expired")
      end
      unless attempt.active?
        raise Aiconshell::Oauth::StateInvalid.new("state_mismatch")
      end

      if error && !error.to_s.empty?
        code = error.to_s == "access_denied" ? "access_denied" : "provider_rejected"
        fail_attempt(attempt, code)
        raise Aiconshell::Oauth::StateInvalid.new(code)
      end

      raise InvalidRequest.new("unexpected_response", "code is missing") if code.nil? || code.to_s.empty?
      unless attempt.consume_once!
        raise Aiconshell::Oauth::StateInvalid.new("state_mismatch")
      end
      # From here the attempt is consumed: exactly one callback proceeds.

      ensure_configured!(name)
      stale_after_reconnect!(attempt)
      config_snapshot_mismatch!(attempt)

      tokens = exchange(name, attempt, code.to_s)
      begin
        verified = verify(name, tokens["access_token"], tokens["scope"])
      rescue Aiconshell::Oauth::Error => e
        fail_attempt(attempt, e.code)
        raise
      end
      connection = persist_connection!(attempt, tokens, verified)
      emit("oauth.callback_succeeded", name,
           { "status" => "connected", "generation" => connection.generation })
      connection
    rescue Aiconshell::Oauth::Error
      raise
    rescue StandardError
      # Never leak raw failures: classify without provider text.
      begin
        fail_attempt(attempt, "provider_error") if attempt&.active?
      rescue StandardError
        nil
      end
      raise Aiconshell::Oauth::ProviderError.new("provider_error")
    end

    # Local disconnect: clears tokens and active attempts so they can never
    # be reused, and bumps the generation so stale callbacks and refreshes
    # are rejected. This only stops the app from using the connection;
    # revoking consent on the provider side is a separate operator action.
    #
    # Locking: the provider advisory xact lock is taken first, then active
    # attempt rows (id order), then the connection row -- the same order as
    # publish. A permanent per-provider row (tombstone) is ensured so the
    # first-connection absence cannot be used to resurrect a connection:
    # a disconnect with no row still creates a disconnected row and bumps
    # the generation past any in-flight attempt.
    def disconnect(provider:)
      name = provider.to_s
      provider_module(name)

      connection = nil
      OauthConnection.transaction do
        advisory_lock!(name)
        attempts = OauthAuthAttempt.lock.where(provider: name, status: %w[pending consumed])
                                       .order(:id).to_a
        row = OauthConnection.lock.find_by(provider: name)
        fresh_now = now
        if row
          row.update!(
            state: "disconnected",
            error_code: "disconnected_local",
            encrypted_access_token: nil,
            encrypted_refresh_token: nil,
            token_expires_at: nil,
            refresh_lease_token: nil,
            refresh_lease_expires_at: nil,
            refresh_lease_generation: nil,
            generation: row.generation + 1
          )
          connection = row
        else
          base = attempts.map(&:generation_at_start).max || 0
          connection = OauthConnection.create!(
            provider: name,
            state: "disconnected",
            error_code: "disconnected_local",
            generation: base + 1
          )
        end
        attempts.each do |attempt|
          attempt.update!(
            status: "expired",
            error_code: "disconnected_local",
            finished_at: fresh_now,
            encrypted_code_verifier: nil
          )
        end
      end
      emit("oauth.disconnected", name,
           { "status" => "disconnected", "generation" => connection&.generation })
      public_status(provider: name)
    end

    # Safe status for diagnostics and the future admin UI. Unset providers
    # report unknown without raising; secrets are never included.
    def public_status(provider:)
      name = provider.to_s
      provider_module(name)
      row = OauthConnection.find_by(provider: name)
      status = row ? row.public_status : {
        "provider" => name,
        "state" => "unknown",
        "connected" => false,
        "principal" => "",
        "display_name" => "",
        "tenant" => nil,
        "cloud" => nil,
        "scopes" => [],
        "token_expires_at" => nil,
        "error_code" => nil,
        "generation" => 0
      }
      status.merge("configured" => @config.missing_env_names(name).empty?)
    end

    private

    def provider_module(name)
      case name
      when "atlassian" then Aiconshell::Oauth::Atlassian
      when "microsoft" then Aiconshell::Oauth::Microsoft
      else raise InvalidRequest.new("provider_error", "unknown oauth provider")
      end
    end

    def session_text(session_id)
      text = session_id.to_s
      raise InvalidRequest.new("state_mismatch", "browser session is missing") if text.empty?

      text
    end

    def ensure_configured!(name)
      missing = @config.missing_env_names(name)
      raise Aiconshell::Oauth::ConfigMissing.new(name, missing) unless missing.empty?

      provider_config = @config.provider(name)
      redirect = provider_config.redirect_uri.to_s
      return fail_config_redirect!(name) unless @config.valid_redirect_uri?(redirect)

      if name == "microsoft" && @config.forbidden_tenant?(provider_config.tenant_id.to_s)
        raise Aiconshell::Oauth::ProviderError.new("tenant_mismatch")
      end

      nil
    end

    def fail_config_redirect!(name)
      raise Aiconshell::Oauth::ConfigMissing.new(name, ["#{redirect_env(name)}_INVALID"])
    end

    def redirect_env(name)
      name == "atlassian" ? "OAUTH_ATLASSIAN_REDIRECT_URI" : "OAUTH_MICROSOFT_REDIRECT_URI"
    end

    def duplicate_state_digest?(error)
      message = error.message.to_s
      message.include?("state_digest") || message.include?("State digest")
    end

    # An attempt started before the latest reconnect/disconnect must not
    # complete: the generation moved on and this callback is stale.
    def stale_after_reconnect!(attempt)
      current = OauthConnection.where(provider: attempt.provider).pick(:generation)
      return if current.nil? || current == attempt.generation_at_start

      fail_attempt(attempt, "expired")
      raise Aiconshell::Oauth::StateInvalid.new("expired")
    end

    # The fixed client/redirect/cloud/tenant/scopes must still match the
    # start snapshot and the current configuration. A configuration change
    # after begin never completes the old attempt.
    def config_snapshot_mismatch!(attempt)
      current = @config.provider(attempt.provider)
      mismatch = attempt.client_id.to_s != current.client_id.to_s ||
        attempt.redirect_uri.to_s != current.redirect_uri.to_s ||
        attempt.scopes.to_s != current.scopes.join(" ").to_s
      if attempt.provider == "atlassian"
        mismatch ||= attempt.cloud_id.to_s != current.cloud_id.to_s
      else
        mismatch ||= attempt.tenant_id.to_s != current.tenant_id.to_s
      end
      return unless mismatch

      fail_attempt(attempt, "expired")
      raise Aiconshell::Oauth::StateInvalid.new("expired")
    end

    def exchange(name, attempt, code)
      fixed_redirect = @config.provider(name).redirect_uri.to_s
      if name == "microsoft"
        verifier = @secret_store.decrypt(attempt.encrypted_code_verifier)
        unless Aiconshell::Oauth::Pkce.valid_verifier?(verifier)
          fail_attempt(attempt, "unexpected_response")
          raise Aiconshell::Oauth::ProviderError.new("unexpected_response")
        end

        Aiconshell::Oauth::Microsoft.exchange_code(
          transport: @transport, config: @config,
          code: code, redirect_uri: fixed_redirect, verifier: verifier
        )
      else
        Aiconshell::Oauth::Atlassian.exchange_code(
          transport: @transport, config: @config,
          code: code, redirect_uri: fixed_redirect
        )
      end
    rescue Aiconshell::Oauth::Error => e
      fail_attempt(attempt, e.code)
      raise
    end

    def verify(name, access_token, granted_scope)
      if name == "microsoft"
        Aiconshell::Oauth::Microsoft.verify_connection(
          transport: @transport, config: @config,
          access_token: access_token, granted_scope: granted_scope
        )
      else
        Aiconshell::Oauth::Atlassian.verify_connection(
          transport: @transport, config: @config, access_token: access_token
        )
      end
    rescue Aiconshell::Oauth::Error => e
      raise e
    end

    # Atomic publish guarded by attempt state, TTL, config snapshot, and
    # generation fencing. The connection row and the attempt success land
    # in one transaction with no network inside; a stale success (expired
    # attempt, replaced/disconnected connection, changed configuration)
    # is discarded instead of resurrecting anything. The first success
    # also bumps the generation so a delayed second attempt cannot
    # replace it. Failures here never touch a healthy row.
    #
    # Locking mirrors disconnect: provider advisory xact lock first, then
    # the attempt row, then the connection row. TTL/lease clocks are read
    # fresh after the locks are held so a wait in the lock queue cannot
    # publish an attempt that expired while waiting.
    def persist_connection!(attempt, tokens, verified)
      encrypted_access = @secret_store.encrypt(tokens["access_token"])
      encrypted_refresh = tokens["refresh_token"] ? @secret_store.encrypt(tokens["refresh_token"]) : nil
      current_config = @config.provider(attempt.provider)

      connection = nil
      OauthConnection.transaction do
        advisory_lock!(attempt.provider)
        attempt_row = OauthAuthAttempt.lock.find_by(id: attempt.id)
        raise Aiconshell::Oauth::StateInvalid.new("expired") if attempt_row.nil?
        raise Aiconshell::Oauth::StateInvalid.new("state_mismatch") unless attempt_row.status == "consumed"
        row = OauthConnection.lock.find_by(provider: attempt_row.provider)
        fresh_now = now
        if attempt_row.expired_due?(fresh_now)
          attempt_row.update!(
            status: "expired", error_code: "expired",
            finished_at: fresh_now, encrypted_code_verifier: nil
          )
          raise Aiconshell::Oauth::StateInvalid.new("expired")
        end
        unless snapshot_matches_current?(attempt_row, current_config)
          attempt_row.update!(
            status: "expired", error_code: "expired",
            finished_at: fresh_now, encrypted_code_verifier: nil
          )
          raise Aiconshell::Oauth::StateInvalid.new("expired")
        end

        if row && row.generation != attempt_row.generation_at_start
          attempt_row.update!(
            status: "expired", error_code: "expired",
            finished_at: fresh_now, encrypted_code_verifier: nil
          )
          raise Aiconshell::Oauth::StateInvalid.new("expired")
        end

        row ||= OauthConnection.new(provider: attempt_row.provider, generation: attempt_row.generation_at_start)
        fresh = row.new_record?
        new_generation = fresh ? attempt_row.generation_at_start + 1 : row.generation + 1
        row.assign_attributes(
          state: "connected",
          error_code: nil,
          client_id: current_config.client_id.to_s,
          external_principal: verified["principal"].to_s,
          display_name: verified["display_name"].to_s,
          tenant_id: verified["tenant_id"],
          cloud_id: verified["cloud_id"],
          granted_scopes: verified["scopes"].to_s,
          encrypted_access_token: encrypted_access,
          encrypted_refresh_token: encrypted_refresh,
          token_expires_at: fresh_now + tokens["expires_in"].to_i,
          refresh_lease_token: nil,
          refresh_lease_expires_at: nil,
          refresh_lease_generation: nil,
          generation: new_generation
        )
        row.save!
        attempt_row.update!(
          status: "succeeded", finished_at: fresh_now, error_code: nil,
          encrypted_code_verifier: nil
        )
        connection = row
      end
      attempt.reload
      connection
    rescue Aiconshell::Oauth::StateInvalid => e
      begin
        fail_attempt(attempt, e.code)
      rescue StandardError
        nil
      end
      raise
    rescue Aiconshell::Oauth::Error
      raise
    rescue StandardError
      # A crash before the save leaves the previous connection intact and
      # the consumed attempt failed with a safe code.
      begin
        fail_attempt(attempt, "provider_error")
      rescue StandardError
        nil
      end
      raise Aiconshell::Oauth::ProviderError.new("provider_error")
    end

    # Short transaction-scoped provider lock shared by publish and
    # disconnect (and the refresh writers in TokenService). It serializes
    # the check-then-create on the possibly-absent connection row and keeps
    # a single lock order, so concurrent publish/disconnect cannot deadlock
    # or resurrect through a phantom row. Never held across network calls.
    def advisory_lock!(provider_name)
      key = "aiconshell:oauth:#{provider_name}"
      quoted = OauthConnection.connection.quote(key)
      OauthConnection.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtext(#{quoted}))"
      )
    end

    def snapshot_matches_current?(attempt_row, current_config)
      return false if attempt_row.client_id.to_s != current_config.client_id.to_s
      return false if attempt_row.redirect_uri.to_s != current_config.redirect_uri.to_s
      return false if attempt_row.scopes.to_s != current_config.scopes.join(" ").to_s

      if attempt_row.provider == "atlassian"
        return false if attempt_row.cloud_id.to_s != current_config.cloud_id.to_s
      else
        return false if attempt_row.tenant_id.to_s != current_config.tenant_id.to_s
      end
      true
    end

    def fail_attempt(attempt, code)
      return if attempt.nil?

      safe = Aiconshell::Oauth::ErrorCodes.sanitize(code)
      attempt.with_lock do
        next unless attempt.active?

        attempt.update!(
          status: attempt.expired_due?(now) ? "expired" : "failed",
          error_code: safe,
          finished_at: now,
          encrypted_code_verifier: nil
        )
      end
      emit("oauth.callback_failed", attempt.provider, { "status" => attempt.status, "error_code" => safe })
    rescue StandardError
      nil
    end

    def emit(kind, provider, data)
      @event_sink.emit(
        layer: "interaction", kind: kind, message: "OAuth #{provider} #{kind}",
        data: { "provider" => provider.to_s }.merge(data || {})
      )
    rescue StandardError
      nil
    end

    def now
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end

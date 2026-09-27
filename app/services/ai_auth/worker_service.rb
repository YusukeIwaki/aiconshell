# frozen_string_literal: true

require "securerandom"
require "uri"

module AiAuth
  # Auth-queue execution. Claims one session row, runs the fixed runtime port
  # with short-lived callbacks, then records a worker-confirmed snapshot.
  # The runtime cleans its child process group on cancel, deadline, timeout,
  # or callback failure; this service only persists safe fixed states.
  class WorkerService
    Result = Struct.new(:ok, :code, keyword_init: true)

    HEARTBEAT_MIN_INTERVAL_SECONDS = 10
    DEFINITIVE_SNAPSHOT_STATES = %w[connected disconnected unavailable failed].freeze

    def initialize(runner: nil, runner_proc: nil, event_sink: WorkflowEvents,
                   clock: Time, worker_role: nil)
      @runner = runner
      @runner_proc = runner_proc
      @event_sink = event_sink
      @clock = clock
      @worker_role_override = worker_role
      @last_heartbeat_write = nil
    end

    def call(session_uuid)
      # Long-running worker: bypass the query cache entirely so cancel and
      # code input from other web/worker connections are always observed.
      ActiveRecord::Base.uncached do
        claimed = claim(session_uuid)
        return claimed if claimed.is_a?(Result)

        session_id, claim_token, provider, operation, worker_role, expires_at = claimed
        if operation == "status_check"
          run_status(session_id, claim_token, provider, worker_role)
        else
          run_login(session_id, claim_token, provider, worker_role, expires_at)
        end
      end
    end

    private

    def claim(session_uuid)
      claimed_row = nil
      AiAuthSession.transaction do
        session = AiAuthSession.lock.find_by(uuid: session_uuid.to_s)
        return Result.new(ok: false, code: :unknown_session) if session.nil?
        return Result.new(ok: false, code: :duplicate_delivery) unless session.status == "queued"

        now_time = now
        if session.expired_due?(now_time)
          finalize(session, status: "expired", result_state: "expired",
                   result_error: "expired", now_time: now_time)
          return Result.new(ok: false, code: :expired)
        end
        if session.cancel_requested
          finalize(session, status: "cancelled", result_state: "cancelled",
                   result_error: "cancelled", now_time: now_time)
          return Result.new(ok: false, code: :cancelled)
        end

        own_role = worker_role
        if own_role.nil? || own_role.empty? || own_role != session.worker_role
          finalize(session, status: "failed", result_state: nil,
                   result_error: "role_mismatch", now_time: now_time, snapshot: false)
          return Result.new(ok: false, code: :role_mismatch)
        end

        token = SecureRandom.uuid
        session.update!(status: "running", claim_token: token,
                        claimed_at: now_time, heartbeat_at: now_time)
        claimed_row = [session.id, token, session.provider, session.operation,
                       session.worker_role, session.expires_at]
      end
      claimed_row
    end

    def run_status(session_id, claim_token, provider, _worker_role)
      runner = active_runner
      unless runner
        return settle(session_id, claim_token, status: "failed", result_state: nil,
                      result_error: "runtime_unavailable", snapshot: false)
      end

      outcome = nil
      begin
        outcome = runner.status(provider: provider)
      rescue StandardError
        return settle(session_id, claim_token, status: "failed", result_state: nil,
                      result_error: "provider_error", snapshot: false)
      end

      state = ErrorCodes.sanitize_state(outcome.is_a?(Hash) ? outcome["state"] : nil)
      code = ErrorCodes.sanitize(outcome.is_a?(Hash) ? outcome["error_code"] : nil)
      unless state && DEFINITIVE_SNAPSHOT_STATES.include?(state)
        return settle(session_id, claim_token, status: "failed", result_state: nil,
                      result_error: "provider_error", snapshot: false)
      end

      settle(session_id, claim_token, status: "succeeded", result_state: state,
             result_error: code, snapshot: true)
    end

    def run_login(session_id, claim_token, provider, _worker_role, expires_at)
      runner = active_runner
      unless runner
        return settle(session_id, claim_token, status: "failed", result_state: nil,
                      result_error: "runtime_unavailable", snapshot: false)
      end

      remaining = [(expires_at - now).to_i, 1].max
      outcome = nil
      begin
        outcome = runner.login(
          provider: provider,
          timeout: [remaining, RequestService::LOGIN_TIMEOUT_SECONDS].min,
          on_challenge: challenge_callback(session_id, claim_token),
          input: input_callback(session_id, claim_token),
          cancelled: cancelled_callback(session_id, claim_token)
        )
      rescue StandardError
        return settle(session_id, claim_token, status: "failed", result_state: nil,
                      result_error: "provider_error", snapshot: false)
      end

      state = ErrorCodes.sanitize_state(outcome.is_a?(Hash) ? outcome["state"] : nil)
      code = ErrorCodes.sanitize(outcome.is_a?(Hash) ? outcome["error_code"] : nil)
      case state
      when "connected"
        settle(session_id, claim_token, status: "succeeded", result_state: state,
               result_error: code, snapshot: true)
      when "disconnected", "unavailable", "failed"
        settle(session_id, claim_token, status: "failed", result_state: state,
               result_error: code, snapshot: true)
      when "cancelled"
        settle(session_id, claim_token, status: "cancelled", result_state: state,
               result_error: code || "cancelled", snapshot: false)
      when "expired"
        settle(session_id, claim_token, status: "expired", result_state: state,
               result_error: code || "expired", snapshot: false)
      else
        settle(session_id, claim_token, status: "failed", result_state: nil,
               result_error: "provider_error", snapshot: false)
      end
    end

    def challenge_callback(session_id, claim_token)
      lambda do |challenge|
        validated = validate_challenge(challenge)
        raise ArgumentError, "invalid challenge" if validated.nil?

        AiAuthSession.transaction do
          session = AiAuthSession.lock.find_by(id: session_id)
          raise ArgumentError, "stale session" unless live_claim?(session, claim_token)
          raise ArgumentError, "session ended" unless session.active?
          raise ArgumentError, "session closed" if session.cancel_requested || session.expired_due?(now)

          session.update!(
            status: "waiting",
            encrypted_challenge: SecretBox.default.encrypt(validated),
            challenge_updated_at: now,
            heartbeat_at: now
          )
          @last_heartbeat_write = now
        end
        nil
      end
    end

    def input_callback(session_id, claim_token)
      lambda do
        maybe_heartbeat(session_id, claim_token)
        code = nil
        AiAuthSession.transaction do
          session = AiAuthSession.lock.find_by(id: session_id)
          next nil unless live_claim?(session, claim_token)
          next nil unless session.active?
          next nil if session.cancel_requested || session.expired_due?(now)

          raw = session.encrypted_input_code
          next nil if raw.nil? || raw.empty?

          begin
            code = SecretBox.default.decrypt(raw)
          rescue StandardError
            code = nil
          end
          session.update_columns(encrypted_input_code: nil, input_updated_at: nil,
                                 updated_at: now)
          code = nil unless code.is_a?(String)
        end
        code
      end
    end

    def cancelled_callback(session_id, claim_token)
      lambda do
        maybe_heartbeat(session_id, claim_token)
        row = ActiveRecord::Base.uncached do
          AiAuthSession.where(id: session_id).pick(:claim_token, :cancel_requested, :expires_at, :status)
        end
        return true if row.nil?
        return true unless row[0] == claim_token
        return true if row[1]
        return true if row[2] && row[2] <= now
        return true unless AiAuthSession::ACTIVE_STATUSES.include?(row[3])

        false
      end
    end

    def maybe_heartbeat(session_id, claim_token)
      now_time = now
      if @last_heartbeat_write && now_time - @last_heartbeat_write < HEARTBEAT_MIN_INTERVAL_SECONDS
        return
      end

      AiAuthSession.transaction do
        session = AiAuthSession.lock.find_by(id: session_id)
        next unless live_claim?(session, claim_token)
        next unless session.active?

        session.update_columns(heartbeat_at: now_time, updated_at: now_time)
        @last_heartbeat_write = now_time
      end
    end

    def settle(session_id, claim_token, status:, result_state:, result_error:, snapshot:)
      now_time = now
      session = nil
      effective_status = status
      effective_state = result_state
      effective_error = result_error
      effective_snapshot = snapshot
      AiAuthSession.transaction do
        row = AiAuthSession.lock.find_by(id: session_id)
        unless live_claim?(row, claim_token)
          return Result.new(ok: false, code: :stale_completion)
        end
        unless row.active?
          return Result.new(ok: false, code: :duplicate_delivery)
        end

        # Re-verify ownership window just before the final write: a cancel
        # or deadline that landed while the runtime was producing its
        # outcome must win over a stale "connected". Secrets are cleared
        # and no snapshot is written for these terminals.
        if row.expired_due?(now_time)
          effective_status = "expired"
          effective_state = "expired"
          effective_error = "expired"
          effective_snapshot = false
        elsif row.cancel_requested
          effective_status = "cancelled"
          effective_state = "cancelled"
          effective_error = "cancelled"
          effective_snapshot = false
        end

        finalize(row, status: effective_status, result_state: effective_state,
                 result_error: effective_error, now_time: now_time)
        session = row
      end
      if effective_snapshot && session && effective_state &&
          DEFINITIVE_SNAPSHOT_STATES.include?(effective_state)
        update_snapshot(session, effective_state, effective_error, now_time)
      end
      emit(session, effective_status)
      Result.new(ok: effective_status == "succeeded", code: effective_status.to_sym)
    end

    def finalize(session, status:, result_state:, result_error:, now_time:, snapshot: nil)
      session.update!(
        status: status,
        result_state: result_state,
        result_error_code: result_error ? ErrorCodes.sanitize(result_error) : nil,
        finished_at: now_time,
        encrypted_challenge: nil,
        challenge_updated_at: nil,
        encrypted_input_code: nil,
        input_updated_at: nil
      )
    end

    # An old job must never overwrite a newer session's snapshot.
    # last_session_id fencing keeps the newest terminal result authoritative
    # even when an old snapshot write lands after a newer one.
    def update_snapshot(session, state, error_code, now_time)
      AiConnection.transaction do
        snapshot = AiConnection.lock.find_by(provider: session.provider, worker_role: session.worker_role)
        if snapshot.nil?
          begin
            AiConnection.transaction(requires_new: true) do
              snapshot = AiConnection.create!(
                provider: session.provider, worker_role: session.worker_role,
                state: state, error_code: error_code ? ErrorCodes.sanitize(error_code) : nil,
                checked_at: now_time, last_session_uuid: session.uuid, last_session_id: session.id
              )
            end
          rescue ActiveRecord::RecordNotUnique
            snapshot = AiConnection.lock.find_by(provider: session.provider, worker_role: session.worker_role)
          end
        end
        return if snapshot.nil?
        return if snapshot.last_session_id && snapshot.last_session_id > session.id

        snapshot.update!(
          state: state,
          error_code: error_code ? ErrorCodes.sanitize(error_code) : nil,
          checked_at: now_time,
          last_session_uuid: session.uuid,
          last_session_id: session.id
        )
      end
    end

    # Worker ops results use coordination for control role and execution for
    # execution role (valid Envelope layers; web intents use interaction).
    def emit(session, status)
      return unless session

      layer = session.worker_role == "execution" ? "execution" : "coordination"
      @event_sink.emit(
        layer: layer, kind: "auth.#{status}", message: "認証操作が#{status}になりました",
        data: { provider: session.provider, worker_role: session.worker_role,
                operation: session.operation, status: status }
      )
    end

    def live_claim?(session, claim_token)
      session && session.claim_token == claim_token && !claim_token.nil?
    end

    def worker_role
      return @worker_role_override unless @worker_role_override.nil?

      ENV.fetch("AICONSHELL_WORKER_ROLE", nil).to_s
    end

    def active_runner
      return @runner unless @runner.nil?
      return @runner_proc.call unless @runner_proc.nil?

      load_runtime_runner
    end

    # No production stub: when the runtime lane has not landed, there is no
    # runner and sessions fail safe as runtime_unavailable. Tests inject a fake.
    def load_runtime_runner
      unless defined?(Aiconshell::Ai::Authentication::Runner)
        begin
          require "aiconshell/ai/authentication"
        rescue LoadError
          return nil
        end
      end
      return nil unless defined?(Aiconshell::Ai::Authentication::Runner)

      config = Aiconshell::Ai::Config.default
      Aiconshell::Ai::Authentication::Runner.new(config: config)
    rescue StandardError
      nil
    end

    def validate_challenge(challenge)
      return nil unless challenge.is_a?(Hash)

      uri = challenge["verification_uri"] || challenge[:verification_uri]
      code = challenge["user_code"] || challenge[:user_code]
      required = challenge["input_required"]
      required = challenge[:input_required] if required.nil?
      return nil unless uri.is_a?(String) && https_url?(uri)
      return nil unless code.nil? || code.is_a?(String)
      return nil unless required == true || required == false
      return nil if !code.nil? && (code.empty? || code.length > 256 || code.include?("\u0000"))

      { "verification_uri" => uri, "user_code" => code, "input_required" => required }
    end

    def https_url?(value)
      return false if value.length > 2048 || value.match?(/[\u0000-\u0020]/)

      parsed = URI.parse(value)
      return false unless parsed.is_a?(URI::HTTPS)
      return false if parsed.userinfo
      return false if parsed.host.nil? || parsed.host.empty?

      true
    rescue URI::InvalidURIError
      false
    end

    def now
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end

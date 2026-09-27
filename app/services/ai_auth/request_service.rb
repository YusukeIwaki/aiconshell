# frozen_string_literal: true

require "securerandom"

module AiAuth
  # Operator intent entry point for AI connection management. Controllers hand
  # an intent here; this service persists the session row and reserves the
  # role-specific auth job. Business tasks and runs are never touched.
  class RequestService
    class InvalidRequest < StandardError
    end

    LOGIN_TIMEOUT_SECONDS = 900
    STATUS_TIMEOUT_SECONDS = 120
    STALE_HEARTBEAT_AFTER_SECONDS = 300
    MAX_CODE_CHARS = 4096

    PROVIDERS = %w[claude codex muse].freeze
    WORKER_ROLES = %w[control execution].freeze

    def initialize(event_sink: WorkflowEvents, clock: Time, job_class: nil)
      @event_sink = event_sink
      @clock = clock
      @job_class = job_class
    end

    def request_login(provider:, worker_role:)
      request(provider: provider, worker_role: worker_role,
              operation: "login", timeout_seconds: LOGIN_TIMEOUT_SECONDS)
    end

    def request_status(provider:, worker_role:)
      request(provider: provider, worker_role: worker_role,
              operation: "status_check", timeout_seconds: STATUS_TIMEOUT_SECONDS)
    end

    def submit_code(session_uuid:, code:)
      text = code.to_s.strip
      raise InvalidRequest, "認証コードを入力してください。" if text.empty?
      raise InvalidRequest, "認証コードが長すぎます。" if text.length > MAX_CODE_CHARS
      raise InvalidRequest, "認証コードが不正です。" if text.include?("\u0000")

      AiAuthSession.transaction do
        session = AiAuthSession.lock.find_by(uuid: session_uuid.to_s)
        raise InvalidRequest, "セッションが見つかりません。" if session.nil?
        raise InvalidRequest, "このセッションは終了しています。" unless session.active?
        raise InvalidRequest, "期限切れです。もう一度お試しください。" if session.expired_due?(now)

        challenge = session.challenge
        if challenge.nil?
          raise InvalidRequest, "まだ入力待ちではありません。認証案内が表示されるまでお待ちください。"
        end
        unless challenge["input_required"]
          raise InvalidRequest, "この手順ではコード入力は不要です。ブラウザで承認してください。"
        end

        ciphertext = SecretBox.default.encrypt(text)
        session.update!(encrypted_input_code: ciphertext, input_updated_at: now)
        session
      end
    end

    def cancel(session_uuid:)
      AiAuthSession.transaction do
        session = AiAuthSession.lock.find_by(uuid: session_uuid.to_s)
        raise InvalidRequest, "セッションが見つかりません。" if session.nil?
        return session if session.terminal?

        session.update!(cancel_requested: true)
        emit(session, "auth.cancel_requested", "認証操作のキャンセルを受け付けました")
        session
      end
    end

    # Mark expired and stale-writer sessions terminal so the next operation
    # can proceed. Safe to call on reads; it only closes rows that can no
    # longer succeed.
    def recover_expired!(provider: nil, worker_role: nil)
      now_time = now
      scope = AiAuthSession.active
      scope = scope.where(provider: provider.to_s) if provider
      scope = scope.where(worker_role: worker_role.to_s) if worker_role
      scope.find_each do |session|
        recover_one(session, now_time)
      end
      nil
    end

    private

    def request(provider:, worker_role:, operation:, timeout_seconds:)
      provider_text = provider.to_s
      role_text = worker_role.to_s
      unless PROVIDERS.include?(provider_text)
        raise InvalidRequest, "プロバイダーが不正です。"
      end
      unless WORKER_ROLES.include?(role_text)
        raise InvalidRequest, "workerの役割が不正です。"
      end

      recover_expired!(provider: provider_text, worker_role: role_text)

      existing = AiAuthSession.active.find_by(provider: provider_text, worker_role: role_text)
      return existing if existing

      now_time = now
      session = nil
      AiAuthSession.transaction do
        session = AiAuthSession.create!(
          uuid: SecureRandom.uuid,
          provider: provider_text,
          worker_role: role_text,
          operation: operation,
          status: "queued",
          expires_at: now_time + timeout_seconds,
          cancel_requested: false
        )
        enqueue(session)
      end
      emit(session, "auth.requested", "認証操作を受け付けました")
      session
    rescue ActiveRecord::RecordNotUnique
      found = AiAuthSession.active.find_by(provider: provider_text, worker_role: role_text)
      raise unless found

      found
    end

    def recover_one(session, now_time)
      session.with_lock do
        next unless session.active?

        if session.expired_due?(now_time)
          close_as(session, "expired", nil, nil, now_time)
          next
        end

        # A claimed session whose worker stopped heartbeating (restart or
        # crash) can never succeed; release it so the next operation works.
        # Queued rows without a worker stay waiting until their deadline.
        next unless %w[running waiting].include?(session.status)

        heartbeat = session.heartbeat_at || session.claimed_at || session.created_at
        if heartbeat && heartbeat <= now_time - STALE_HEARTBEAT_AFTER_SECONDS
          close_as(session, "expired", "expired", "expired", now_time)
        end
      end
    end

    def close_as(session, status, result_state, result_error, now_time)
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
      emit(session, "auth.expired", "認証操作が期限切れになりました")
    end

    def enqueue(session)
      job = @job_class || AiAuthJob
      job.set(queue: "ai_auth_#{session.worker_role}").perform_later(session.uuid)
    end

    def emit(session, kind, message)
      @event_sink.emit(
        layer: "control", kind: kind, message: message,
        data: { provider: session.provider, worker_role: session.worker_role,
                operation: session.operation, status: session.status }
      )
    end

    def now
      @clock.respond_to?(:current) ? @clock.current : @clock.now
    end
  end
end

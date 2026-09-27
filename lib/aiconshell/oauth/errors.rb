# frozen_string_literal: true

module Aiconshell
  module Oauth
    # Typed failures for the OAuth foundation. Messages carry only safe
    # classification codes and sanitized origins; provider bodies, secrets,
    # and raw parser text never reach messages, logs, or EventLog data.
    class Error < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        @code = ErrorCodes.sanitize(code)
        super(message || "oauth operation failed (#{@code})")
      end
    end

    # Provider settings or credentials are absent. Only variable *names*
    # are reported, never values.
    class ConfigMissing < Error
      attr_reader :provider, :missing

      def initialize(provider, missing)
        @provider = provider.to_s
        @missing = Array(missing).map(&:to_s)
        super("unconfigured", "oauth #{@provider} is not configured: #{@missing.join(", ")}")
      end
    end

    # The callback did not match its auth attempt (unknown/reused/expired
    # state, wrong browser session, denied consent, stale generation).
    class StateInvalid < Error
      def initialize(code, message = nil)
        super(code, message || "oauth callback was rejected (#{ErrorCodes.sanitize(code)})")
      end
    end

    # The provider or the network rejected the exchange/refresh/verify call.
    # Carries the safe code only; raw status text stays in the transport.
    class ProviderError < Error
      def initialize(code, message = nil)
        super(code, message || "oauth provider call failed (#{ErrorCodes.sanitize(code)})")
      end
    end

    # A credential binding no longer matches the stored connection
    # (replaced/disconnected). Raised before any external write.
    class BindingMismatch < Error
      def initialize(message = nil)
        super("binding_mismatch", message || "oauth credential binding does not match the current connection")
      end
    end

    # Another refresh already holds the exclusive lease.
    class RefreshBusy < Error
      def initialize(message = nil)
        super("refresh_in_progress", message || "oauth refresh is already in progress")
      end
    end

    # Safe fixed classification. Only the allowlist below is ever persisted
    # or emitted; anything else collapses to provider_error so provider text
    # can never reach the database, the UI, or EventLog.
    module ErrorCodes
      CONNECTION_STATES = %w[unknown connected needs_reauth disconnected failed].freeze
      ATTEMPT_STATUSES = %w[pending consumed succeeded failed expired].freeze

      ALLOWED_CODES = %w[
        unconfigured not_connected state_mismatch expired access_denied
        scope_mismatch cloud_mismatch tenant_mismatch principal_mismatch
        unexpected_response invalid_grant rate_limited timeout
        transport_error provider_rejected provider_error
        binding_mismatch refresh_in_progress disconnected_local
      ].freeze

      GENERIC_CODE = "provider_error"

      # Codes that mean the user must reconnect (refresh can never succeed).
      NEEDS_REAUTH_CODES = %w[invalid_grant].freeze

      # Codes worth retrying later without reconnecting.
      TRANSIENT_CODES = %w[rate_limited timeout transport_error].freeze

      JAPANESE_STATE = {
        "unknown" => "未確認",
        "connected" => "接続済み",
        "needs_reauth" => "再接続が必要",
        "disconnected" => "未接続",
        "failed" => "失敗"
      }.freeze

      JAPANESE_CODE = {
        "unconfigured" => "OAuth接続の設定がありません。管理者に連絡してください。",
        "not_connected" => "OAuth接続がありません。管理画面から接続してください。",
        "state_mismatch" => "認証の検証に失敗しました。もう一度お試しください。",
        "expired" => "認証の有効期限が切れました。もう一度お試しください。",
        "access_denied" => "同意が拒否されました。もう一度お試しください。",
        "scope_mismatch" => "必要な権限が付与されませんでした。もう一度同意してください。",
        "cloud_mismatch" => "接続先の確認に失敗しました。設定を確認してください。",
        "tenant_mismatch" => "接続先の確認に失敗しました。設定を確認してください。",
        "principal_mismatch" => "接続ユーザーの確認に失敗しました。もう一度お試しください。",
        "unexpected_response" => "認証処理で想定外の応答がありました。もう一度お試しください。",
        "invalid_grant" => "接続の有効期限が切れました。再接続してください。",
        "rate_limited" => "処理が混み合っています。しばらくしてからお試しください。",
        "timeout" => "処理がタイムアウトしました。もう一度お試しください。",
        "transport_error" => "通信に失敗しました。もう一度お試しください。",
        "provider_rejected" => "認証が拒否されました。もう一度お試しください。",
        "provider_error" => "認証処理でエラーが発生しました。もう一度お試しください。",
        "binding_mismatch" => "接続が変更されました。最新の接続でやり直してください。",
        "refresh_in_progress" => "更新処理が進行中です。しばらくしてからお試しください。",
        "disconnected_local" => "接続を解除しました。"
      }.freeze

      module_function

      def sanitize(code)
        return nil if code.nil? || code.to_s.empty?

        text = code.to_s
        ALLOWED_CODES.include?(text) ? text : GENERIC_CODE
      end

      def sanitize_state(state)
        text = state.to_s
        CONNECTION_STATES.include?(text) ? text : nil
      end

      def needs_reauth?(code)
        NEEDS_REAUTH_CODES.include?(code.to_s)
      end

      def transient?(code)
        TRANSIENT_CODES.include?(code.to_s)
      end

      def japanese_state(state)
        JAPANESE_STATE.fetch(state.to_s, "不明")
      end

      def japanese_code(code)
        return "" if code.nil? || code.to_s.empty?

        JAPANESE_CODE.fetch(code.to_s, JAPANESE_CODE.fetch(GENERIC_CODE))
      end
    end
  end
end

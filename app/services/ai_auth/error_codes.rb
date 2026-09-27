# frozen_string_literal: true

module AiAuth
  # Safe fixed error classification and Japanese presentation. The runtime
  # only returns allowlisted codes; anything else is collapsed to a generic
  # failure so raw CLI text can never reach the database or the UI.
  module ErrorCodes
    SNAPSHOT_STATES = %w[unknown connected disconnected unavailable failed].freeze
    RUNTIME_STATES = %w[connected disconnected unavailable failed cancelled expired].freeze

    JAPANESE_STATE = {
      "unknown" => "未確認",
      "connected" => "接続済み",
      "disconnected" => "未連携",
      "unavailable" => "準備不足",
      "failed" => "失敗",
      "cancelled" => "取消",
      "expired" => "期限切れ"
    }.freeze

    JAPANESE_CODE = {
      "cli_missing" => "CLIまたは認証場所が見つかりません。workerのイメージとvolumeを確認してください。",
      "auth_required" => "ログインが必要です。連携開始からログインしてください。",
      "auth_expired" => "認証の有効期限が切れました。再度ログインしてください。",
      "auth_denied" => "認証が拒否されました。承認操作を確認してもう一度お試しください。",
      "timeout" => "処理がタイムアウトしました。もう一度お試しください。",
      "cancelled" => "キャンセルされました。",
      "expired" => "期限切れです。もう一度お試しください。",
      "role_mismatch" => "workerの役割が一致しません。queue設定を確認してください。",
      "invalid_request" => "要求が不正です。もう一度お試しください。",
      "invalid_challenge" => "認証案内の検証に失敗しました。もう一度お試しください。",
      "callback_failed" => "認証処理中にエラーが発生しました。もう一度お試しください。",
      "runtime_unavailable" => "認証ランタイムが利用できません。workerのデプロイを確認してください。",
      "unavailable" => "一時的に利用できません。もう一度お試しください。",
      "usage_limit" => "利用上限に達しました。しばらく待ってから再試行してください。",
      "not_configured" => "workerの準備ができていません。設定を確認してください。",
      "provider_error" => "認証処理でエラーが発生しました。もう一度お試しください。"
    }.freeze

    GENERIC_CODE = "provider_error"

    module_function

    def sanitize(code)
      return nil if code.nil?
      return nil if code == ""

      text = code.to_s
      return text if text.match?(/\A[a-z0-9_]{1,64}\z/)

      GENERIC_CODE
    end

    def sanitize_state(state)
      text = state.to_s
      RUNTIME_STATES.include?(text) ? text : nil
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

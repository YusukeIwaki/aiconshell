# frozen_string_literal: true

module AiAuth
  # Safe fixed error classification and Japanese presentation. Only the
  # explicit allowlist below is ever persisted; anything else (including
  # safe-looking lowercase strings) collapses to provider_error so raw CLI
  # text and future codes can never reach the database, the UI, or EventLog.
  module ErrorCodes
    SNAPSHOT_STATES = %w[unknown connected disconnected unavailable failed].freeze
    RUNTIME_STATES = %w[connected disconnected unavailable failed cancelled expired].freeze

    # Fixed runtime vocabulary (Issue #16 contract). Unknown runtime codes
    # are not persisted; they collapse to provider_error.
    RUNTIME_ERROR_CODES = %w[
      invalid_provider invalid_argument spawn_failed timeout unexpected_output
      output_capped challenge_rejected auth_rejected callback_failed
      input_failed cancel_check_failed interrupted unknown
    ].freeze

    # UI/ops-specific fixed codes for worker management itself.
    UI_ERROR_CODES = %w[
      cancelled expired role_mismatch runtime_unavailable provider_error
    ].freeze

    ALLOWED_CODES = (RUNTIME_ERROR_CODES + UI_ERROR_CODES).freeze

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
      "invalid_provider" => "プロバイダーが不正です。もう一度お試しください。",
      "invalid_argument" => "要求が不正です。もう一度お試しください。",
      "spawn_failed" => "認証プロセスの起動に失敗しました。workerの状態を確認してください。",
      "timeout" => "処理がタイムアウトしました。もう一度お試しください。",
      "unexpected_output" => "認証処理で想定外の応答がありました。もう一度お試しください。",
      "output_capped" => "認証処理の出力が大きすぎます。もう一度お試しください。",
      "challenge_rejected" => "認証案内の検証に失敗しました。もう一度お試しください。",
      "auth_rejected" => "認証が拒否されました。承認操作を確認してもう一度お試しください。",
      "callback_failed" => "認証処理中にエラーが発生しました。もう一度お試しください。",
      "input_failed" => "コードの受け渡しに失敗しました。もう一度お試しください。",
      "cancel_check_failed" => "取消確認に失敗しました。もう一度お試しください。",
      "interrupted" => "処理が中断されました。もう一度お試しください。",
      "unknown" => "認証処理で不明なエラーが発生しました。もう一度お試しください。",
      "cancelled" => "キャンセルされました。",
      "expired" => "期限切れです。もう一度お試しください。",
      "role_mismatch" => "workerの役割が一致しません。queue設定を確認してください。",
      "runtime_unavailable" => "認証ランタイムが利用できません。workerのデプロイを確認してください。",
      "provider_error" => "認証処理でエラーが発生しました。もう一度お試しください。"
    }.freeze

    GENERIC_CODE = "provider_error"

    module_function

    def sanitize(code)
      return nil if code.nil?
      return nil if code == ""

      text = code.to_s
      return text if ALLOWED_CODES.include?(text)

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

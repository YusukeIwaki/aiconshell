# frozen_string_literal: true

module AiConnectionsHelper
  PROVIDER_LABELS = {
    "claude" => "Claude",
    "codex" => "Codex",
    "muse" => "Muse Code"
  }.freeze

  ROLE_LABELS = {
    "control" => "control worker",
    "execution" => "execution worker"
  }.freeze

  # Single-worker contract (issue 20): every layer uses the shared
  # execution worker. The control label stays only for legacy records.
  LAYER_ROLE_ROWS = [
    ["対話層", "interaction", "execution"],
    ["整理層", "coordination", "execution"],
    ["実行層", "execution", "execution"]
  ].freeze

  def ai_provider_label(provider)
    PROVIDER_LABELS.fetch(provider.to_s, provider.to_s)
  end

  def ai_role_label(role)
    ROLE_LABELS.fetch(role.to_s, role.to_s)
  end

  def ai_state_label(state)
    AiAuth::ErrorCodes.japanese_state(state)
  end

  def ai_state_badge(state)
    case state.to_s
    when "connected"
      "admin-badge-good"
    when "disconnected", "unavailable"
      "admin-badge-warn"
    when "failed"
      "admin-badge-bad"
    else
      "admin-badge-idle"
    end
  end

  def ai_session_label(status)
    {
      "queued" => "待機中",
      "running" => "処理中",
      "waiting" => "入力待ち",
      "succeeded" => "完了",
      "failed" => "失敗",
      "cancelled" => "取消",
      "expired" => "期限切れ"
    }.fetch(status.to_s, status.to_s)
  end

  def ai_session_badge(status)
    case status.to_s
    when "succeeded"
      "admin-badge-good"
    when "failed", "expired"
      "admin-badge-bad"
    when "queued", "running", "waiting"
      "admin-badge-warn"
    else
      "admin-badge-idle"
    end
  end

  def ai_operation_label(operation)
    operation.to_s == "login" ? "連携開始" : "状態確認"
  end

  def ai_error_text(code)
    AiAuth::ErrorCodes.japanese_code(code)
  end

  def ai_layer_role_rows
    LAYER_ROLE_ROWS
  end

  # Short safe label for the verified auth URL; the long secret query stays
  # in href only and never becomes the visible link text.
  def ai_verification_link_label(provider)
    "#{ai_provider_label(provider)}公式認証画面を開く"
  end
end

# frozen_string_literal: true

require "aiconshell/oauth" unless defined?(Aiconshell::Oauth::ErrorCodes)

module AdminHelper
  TASK_STATUS_LABELS = {
    "inbox" => "受信箱",
    "ready" => "実行待ち",
    "running" => "実行中",
    "waiting_human" => "人間待ち",
    "waiting_review" => "レビュー待ち",
    "waiting_delivery" => "配送待ち",
    "done" => "完了",
    "failed" => "失敗",
    "cancelled" => "取消"
  }.freeze

  LAYER_LABELS = {
    "interaction" => "対話層",
    "coordination" => "整理層",
    "execution" => "実行層"
  }.freeze

  OUTBOUND_STATUS_LABELS = {
    "pending" => "送信待ち",
    "sending" => "送信中",
    "sent" => "送信済み",
    "failed" => "失敗",
    "uncertain" => "未確定"
  }.freeze

  def task_status_label(status)
    TASK_STATUS_LABELS.fetch(status.to_s, status.to_s)
  end

  def layer_label(layer)
    LAYER_LABELS.fetch(layer.to_s, layer.to_s)
  end

  def outbound_status_label(status)
    OUTBOUND_STATUS_LABELS.fetch(status.to_s, status.to_s)
  end

  OAUTH_STATE_LABELS = {
    "unconfigured" => "未設定",
    "unknown" => "未接続",
    "disconnected" => "未接続",
    "connecting" => "接続中",
    "connected" => "接続済み",
    "needs_reauth" => "再認証必要",
    "failed" => "失敗"
  }.freeze

  OAUTH_STATE_BADGES = {
    "unconfigured" => "admin-badge-idle",
    "unknown" => "admin-badge-idle",
    "disconnected" => "admin-badge-idle",
    "connecting" => "admin-badge-warn",
    "connected" => "admin-badge-good",
    "needs_reauth" => "admin-badge-warn",
    "failed" => "admin-badge-bad"
  }.freeze

  def admin_nav_items
    [
      ["タスクボード", admin_tasks_path, "tasks"],
      ["AIポリシー", admin_layer_policies_path, "layer_policies"],
      ["AI連携", admin_ai_connections_path, "ai_connections"],
      ["OAuth連携", admin_oauth_connections_path, "oauth_connections"],
      ["プラグイン", admin_plugins_path, "plugins"],
      ["EventLog検索", admin_event_logs_path, "event_logs"]
    ]
  end

  def admin_nav_active?(key)
    controller.controller_path == "admin/#{key}" ||
      (key == "tasks" && controller.controller_path == "admin/feedbacks")
  end

  # User-delegated OAuth display state (issue #23). "設定済み" (env
  # present) and "接続済み" (verified connection) are separate badges;
  # this key selects only the connection badge. A live attempt is shown
  # as an extra 接続中 badge, never by replacing the connection badge:
  # the verified principal stays visible while reconnecting. With no
  # connection, a real latest failed attempt surfaces as 失敗 so an
  # initial failure is distinguishable from 未接続. Unknown states fall
  # back to 未接続, never to 接続済み.
  def oauth_display_state(row)
    row = row.is_a?(Hash) ? row : {}
    return "unconfigured" unless row["configured"]

    case row["state"].to_s
    when "connected" then "connected"
    when "needs_reauth" then "needs_reauth"
    when "failed" then "failed"
    else
      return "failed" if row["attempt_error"].present?

      "disconnected"
    end
  end

  # True when a verified connection exists, independent of the live
  # attempt flag and configuration. Used to keep the principal table
  # visible while a reconnect attempt is pending or env went missing.
  def oauth_shows_identity?(row)
    row = row.is_a?(Hash) ? row : {}
    %w[connected needs_reauth failed].include?(row["state"].to_s)
  end

  # Local disconnect stays available while identity exists or a live
  # attempt exists (attempt invalidation), even when unconfigured.
  def oauth_shows_disconnect?(row)
    row = row.is_a?(Hash) ? row : {}
    oauth_shows_identity?(row) || !!row["connecting"]
  end

  # Latest real failed attempt for the provider row, if any. Shown
  # separately from the connection badge so a failed reconnect never
  # overwrites the healthy connection display.
  def oauth_attempt_error(row)
    row = row.is_a?(Hash) ? row : {}
    code = row["attempt_error"].to_s
    code.empty? ? nil : code
  end

  def oauth_state_label(state_key)
    OAUTH_STATE_LABELS.fetch(state_key.to_s, "未接続")
  end

  def oauth_state_badge(state_key)
    OAUTH_STATE_BADGES.fetch(state_key.to_s, "admin-badge-idle")
  end

  # Fixed cloud/tenant id for the verified connection (never a secret).
  def oauth_fixed_id(row)
    row = row.is_a?(Hash) ? row : {}
    id = row["provider"].to_s == "microsoft" ? row["tenant"] : row["cloud"]
    id.presence || "―"
  end

  def oauth_scopes_label(row)
    scopes = row.is_a?(Hash) ? Array(row["scopes"]) : []
    names = scopes.map(&:to_s).reject(&:empty?)
    names.empty? ? "―" : names.join(" ")
  end

  # Foundation error codes map to fixed Japanese strings (never exception
  # or provider text).
  def oauth_error_label(code)
    Aiconshell::Oauth::ErrorCodes.japanese_code(code)
  end
end

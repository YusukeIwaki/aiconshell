# frozen_string_literal: true

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

  def admin_nav_items
    [
      ["タスクボード", admin_tasks_path, "tasks"],
      ["AIポリシー", admin_layer_policies_path, "layer_policies"],
      ["AI連携", admin_ai_connections_path, "ai_connections"],
      ["プラグイン", admin_plugins_path, "plugins"],
      ["EventLog検索", admin_event_logs_path, "event_logs"]
    ]
  end

  def admin_nav_active?(key)
    controller.controller_path == "admin/#{key}" ||
      (key == "tasks" && controller.controller_path == "admin/feedbacks")
  end
end

# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("policy index aligns operation column for saved and unset rows") do |http:|
  # Single saved layer: the two unset rows must still fill the 7-column
  # header so their operation cells line up under 操作.
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    rows = body.scan(/<tr>(.*?)<\/tr>/m).map(&:first)
    expect(rows.size).to eq(4)
    expect(rows.first.scan(/<th/).size).to eq(7)

    # Every data row covers all 7 header columns (colspan-aware).
    rows[1..].each do |row_html|
      width = row_html.scan(/<td([^>]*)>/).sum do |attrs|
        span = attrs.first[/colspan="(\d+)"/, 1]
        span ? span.to_i : 1
      end
      expect(width).to eq(7)
    end

    # Locate rows by the layer slug cell: every saved row now renders an
    # "execution worker" badge, so a bare "execution" substring is ambiguous.
    coord_row = rows.find { |r| r.include?("（coordination）") }
    interaction_row = rows.find { |r| r.include?("（interaction）") }
    execution_row = rows.find { |r| r.include?("（execution）") }
    expect(coord_row.nil?).to eq(false)
    expect(interaction_row.nil?).to eq(false)
    expect(execution_row.nil?).to eq(false)

    # Saved row owns its recheck form; unset rows never do.
    coord_form = coord_row[/<form[^>]*action="\/admin\/layer_policies\/coordination\/connection_check"[^>]*>.*?<\/form>/m, 0]
    expect(coord_form.nil?).to eq(false)
    expect(coord_form.include?("接続状態を再確認")).to eq(true)
    expect(interaction_row.include?("connection_check")).to eq(false)
    expect(execution_row.include?("connection_check")).to eq(false)

    # Unset rows keep 編集 and 設定が必要です together in the operation cell.
    [interaction_row, execution_row].each do |row_html|
      cells = row_html.scan(/<td[^>]*>(.*?)<\/td>/m).map(&:first)
      operation_cell = cells.last.to_s
      expect(operation_cell.include?("編集")).to eq(true)
      expect(operation_cell.include?("設定が必要です")).to eq(true)
    end
  end
end

test("recheck accepts saved provider and lands on connections without claiming connected") do |http:|
  policy = LayerPolicy.create!(layer: "coordination", provider: "codex",
                               model: "m", effort: "max", instructions: "丁寧に",
                               enabled: true)
  before_policy = policy.attributes.slice("layer", "provider", "model", "effort", "instructions", "enabled")
  task = Task.create!(title: "業務タスク", status: "inbox")
  before_snapshot_count = AiConnection.count
  expect(TaskRun.count).to eq(0)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/coordination/connection_check"
    expect(http.last_response.status).to eq(302)
    location = http.last_response.headers["Location"]
    expect(location.include?("/admin/ai_connections")).to eq(true)

    session = AiAuthSession.active.find_by(provider: "codex", worker_role: "execution")
    expect(session.nil?).to eq(false)
    expect(session.operation).to eq("status_check")
    expect(SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_execution").count).to eq(1)

    # Saved policy and business records are untouched; no snapshot is written at accept time.
    expect(policy.reload.attributes.slice("layer", "provider", "model", "effort", "instructions", "enabled")).to eq(before_policy)
    expect(task.reload.status).to eq("inbox")
    expect(Task.count).to eq(1)
    expect(TaskRun.count).to eq(0)
    expect(AiConnection.count).to eq(before_snapshot_count)

    http.follow_redirect!
    body = http.last_response.body
    notice = body[/<p class="admin-flash admin-flash-notice">(.*?)<\/p>/m, 1].to_s
    expect(notice.include?("接続状態の再確認を受け付けました")).to eq(true)
    expect(notice.include?("接続済み")).to eq(false)
    expect(body.include?("Codexと連携")).to eq(true)
  end
end

test("execution layer rechecks the execution role, not control") do |http:|
  LayerPolicy.create!(layer: "execution", provider: "muse", enabled: true)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/execution/connection_check"
    expect(http.last_response.status).to eq(302)

    expect(AiAuthSession.active.find_by(provider: "muse", worker_role: "execution").nil?).to eq(false)
    expect(AiAuthSession.active.find_by(provider: "muse", worker_role: "control").nil?).to eq(true)
  end
end

test("disabled and disconnected policies can still be rechecked") do |http:|
  LayerPolicy.create!(layer: "interaction", provider: "claude", enabled: false)
  AiConnection.create!(provider: "claude", worker_role: "execution",
                       state: "disconnected", checked_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/interaction/connection_check"
    expect(http.last_response.status).to eq(302)

    session = AiAuthSession.active.find_by(provider: "claude", worker_role: "execution")
    expect(session.nil?).to eq(false)
    expect(session.operation).to eq("status_check")
    expect(LayerPolicy.find_by(layer: "interaction").enabled).to eq(false)
  end
end

test("unset layer is rejected without creating a session") do |http:|
  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/coordination/connection_check"
    expect(http.last_response.status).to eq(302)
    expect(http.last_response.headers["Location"].include?("/admin/layer_policies")).to eq(true)
    expect(AiAuthSession.count).to eq(0)
    expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(0)

    http.follow_redirect!
    expect(http.last_response.body.include?("設定が必要です")).to eq(true)
  end
end

test("unknown layer never runs the operation") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/billing/connection_check"
    expect(http.last_response.status).to eq(302)
    expect(AiAuthSession.count).to eq(0)
    expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(0)
  end
end

test("extra provider params cannot retarget the saved setting") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/coordination/connection_check",
      { provider: "muse", worker_role: "execution", layer_policy: { provider: "muse" } }
    expect(http.last_response.status).to eq(302)

    expect(AiAuthSession.active.find_by(provider: "codex", worker_role: "execution").nil?).to eq(false)
    expect(AiAuthSession.find_by(provider: "muse")).to eq(nil)

    http.post "/admin/layer_policies/coordination/connection_check", { provider: "gpt" }
    expect(AiAuthSession.count).to eq(1)
    expect(AiAuthSession.active.first.provider).to eq("codex")
  end
end

test("rapid recheck reuses the active session and reports progress consistently") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/coordination/connection_check"
    first = AiAuthSession.active.find_by(provider: "codex", worker_role: "execution")
    expect(first.nil?).to eq(false)
    http.follow_redirect!
    first_notice = http.last_response.body[/<p class="admin-flash admin-flash-notice">(.*?)<\/p>/m, 1].to_s
    expect(first_notice.include?("接続状態の再確認を受け付けました")).to eq(true)

    http.post "/admin/layer_policies/coordination/connection_check"
    expect(http.last_response.status).to eq(302)
    expect(AiAuthSession.active.where(provider: "codex", worker_role: "execution").count).to eq(1)
    expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(1)
    expect(AiAuthSession.active.find_by(provider: "codex", worker_role: "execution").uuid).to eq(first.uuid)

    http.follow_redirect!
    second_notice = http.last_response.body[/<p class="admin-flash admin-flash-notice">(.*?)<\/p>/m, 1].to_s
    expect(second_notice.include?("接続状態の再確認を受け付けました")).to eq(false)
    expect(second_notice.include?("進行中")).to eq(true)
  end
end

test("in-progress login for the same provider is kept and reported as login") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "claude", enabled: true)
  # Fresh queued login (created within seconds) shares the provider/role slot.
  login = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "claude", worker_role: "execution")
  expect(login.operation).to eq("login")
  expect(login.status).to eq("queued")

  AdminTestSupport.as_admin(http) do
    http.post "/admin/layer_policies/coordination/connection_check"
    expect(http.last_response.status).to eq(302)

    expect(AiAuthSession.active.where(provider: "claude", worker_role: "execution").count).to eq(1)
    kept = AiAuthSession.active.find_by(provider: "claude", worker_role: "execution")
    expect(kept.uuid).to eq(login.uuid)
    expect(kept.operation).to eq("login")
    expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(1)

    http.follow_redirect!
    notice = http.last_response.body[/<p class="admin-flash admin-flash-notice">(.*?)<\/p>/m, 1].to_s
    expect(notice.include?("接続状態の再確認を受け付けました")).to eq(false)
    expect(notice.include?("進行中のログイン")).to eq(true)
  end
end

test("recheck requires admin auth") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_anonymous(http) do
    http.post "/admin/layer_policies/coordination/connection_check"
    expect(http.last_response.status).to eq(401)
    expect(AiAuthSession.count).to eq(0)
  end
end

test("CSRF: recheck POST without token is rejected") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.post "/admin/layer_policies/coordination/connection_check"
      expect(http.last_response.status).to eq(422)
      expect(AiAuthSession.count).to eq(0)
    end
  end
end

test("CSRF: recheck POST with form token succeeds") do |http:|
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)

  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.get "/admin/layer_policies"
      body = http.last_response.body
      form = body[/<form[^>]*action="\/admin\/layer_policies\/coordination\/connection_check"[^>]*>.*?<\/form>/m, 0]
      expect(form.nil?).to eq(false)
      token = form[/name="authenticity_token" value="([^"]+)"/, 1]
      expect(token.nil?).to eq(false)

      http.post "/admin/layer_policies/coordination/connection_check", { authenticity_token: token }
      expect(http.last_response.status).to eq(302)
      expect(AiAuthSession.active.find_by(provider: "codex", worker_role: "execution").nil?).to eq(false)
    end
  end
end

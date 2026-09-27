# frozen_string_literal: true

require "db_helper"
require_relative "support/admin_test_support"

test("ai connections index requires admin auth") do |http:|
  AdminTestSupport.as_anonymous(http) do
    http.get "/admin/ai_connections"
    expect(http.last_response.status).to eq(401)

    http.post "/admin/ai_connections/login", { provider: "claude", worker_role: "control" }
    expect(http.last_response.status).to eq(401)

    http.post "/admin/ai_connections/status_check", { provider: "claude", worker_role: "control" }
    expect(http.last_response.status).to eq(401)
  end
end

test("ai connections index lists all six provider and role pairs in Japanese") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"

    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    %w[claude codex muse].each do |provider|
      expect(body.include?(provider)).to eq(true)
    end
    %w[control execution].each do |role|
      expect(body.include?(role)).to eq(true)
    end
    expect(body.include?("別の永続volume")).to eq(true)
    expect(body.include?("対話層")).to eq(true)
    expect(body.include?("整理層")).to eq(true)
    expect(body.include?("実行層")).to eq(true)
    expect(body.include?("未確認")).to eq(true)
    # No CLI surface or raw output leaks into the page.
    expect(body.include?("claude auth login")).to eq(false)
    expect(body.include?("codex login")).to eq(false)
  end
end

test("index carries no-store cache and no-referrer policy") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"

    expect(http.last_response.headers["Cache-Control"]).to eq("no-store")
    expect(http.last_response.headers["Referrer-Policy"]).to eq("no-referrer")
  end
end

test("login start creates one session and one role job, double submit reuses it") do |http:|
  AdminTestSupport.as_admin(http) do
    http.post "/admin/ai_connections/login", { provider: "claude", worker_role: "control" }
    expect(http.last_response.status).to eq(302)

    first = AiAuthSession.active.find_by(provider: "claude", worker_role: "control")
    expect(first.nil?).to eq(false)
    expect(first.operation).to eq("login")
    expect(SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_control").count).to eq(1)

    http.post "/admin/ai_connections/login", { provider: "claude", worker_role: "control" }
    expect(http.last_response.status).to eq(302)
    expect(AiAuthSession.active.where(provider: "claude", worker_role: "control").count).to eq(1)
    expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(1)

    http.get "/admin/ai_connections"
    body = http.last_response.body
    expect(body.include?("待機中") || body.include?("処理中") || body.include?("入力待ち")).to eq(true)
    expect(body.include?("refresh")).to eq(true)
  end
end

test("status check and login are rejected for unknown provider or role") do |http:|
  AdminTestSupport.as_admin(http) do
    http.post "/admin/ai_connections/login", { provider: "gpt", worker_role: "control" }
    expect(http.last_response.status).to eq(302)
    expect(AiAuthSession.count).to eq(0)

    http.post "/admin/ai_connections/status_check", { provider: "claude", worker_role: "web" }
    expect(http.last_response.status).to eq(302)
    expect(AiAuthSession.count).to eq(0)
  end
end

test("challenge URL renders as a safe external link with user code") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "codex", worker_role: "execution")
  session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/device/test-link",
        "user_code" => "TEST-CODE-1", "input_required" => false }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"
    body = http.last_response.body

    expect(body.include?("https://example.invalid/device/test-link")).to eq(true)
    expect(body.include?("noopener")).to eq(true)
    expect(body.include?("noreferrer")).to eq(true)
    expect(body.include?("TEST-CODE-1")).to eq(true)
    expect(body.include?("コード入力は不要")).to eq(true)
    # Ciphertext itself never renders.
    expect(body.include?(session.reload.encrypted_challenge.to_s[0, 20])).to eq(false)
  end
end

test("code input only renders when the challenge requires it") do |http:|
  needing = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "claude", worker_role: "control")
  needing.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://claude.ai/oauth/test-input",
        "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"
    expect(http.last_response.body.include?("auth_code")).to eq(true)

    http.post "/admin/ai_connections/#{needing.uuid}/code", { auth_code: "  input-secret-7 " }
    expect(http.last_response.status).to eq(302)
    expect(needing.reload.input_code_present?).to eq(true)
    expect(needing.encrypted_input_code.include?("input-secret-7")).to eq(false)
  end
end

test("cancel flags the session from the UI") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "muse", worker_role: "control")

  AdminTestSupport.as_admin(http) do
    http.post "/admin/ai_connections/#{session.uuid}/cancel"
    expect(http.last_response.status).to eq(302)
    expect(session.reload.cancel_requested).to eq(true)
  end
end

test("expired sessions recover on index and never render as success") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "claude", worker_role: "execution")
  session.update_columns(expires_at: 1.minute.ago, updated_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"

    expect(http.last_response.status).to eq(200)
    expect(session.reload.status).to eq("expired")
    expect(http.last_response.body.include?("接続済み")).to eq(false)
  end
end

test("snapshot states and safe errors render in Japanese, raw text never leaks") do |http:|
  AiConnection.create!(provider: "claude", worker_role: "control",
                       state: "connected", checked_at: Time.current)
  AiConnection.create!(provider: "codex", worker_role: "control",
                       state: "unavailable", error_code: "raw stderr SECRET-999",
                       checked_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"
    body = http.last_response.body

    expect(body.include?("接続済み")).to eq(true)
    expect(body.include?("準備不足")).to eq(true)
    expect(body.include?("SECRET-999")).to eq(false)
    expect(body.include?("raw stderr")).to eq(false)
  end
end

test("unconfigured providers stay selectable for layer policies") do |http:|
  AiConnection.create!(provider: "muse", worker_role: "execution",
                       state: "disconnected", checked_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.patch "/admin/layer_policies/execution",
      { layer_policy: { provider: "muse", model: "m", effort: "max", instructions: "x", enabled: "1" } }
    expect(http.last_response.status).to eq(302)
    expect(LayerPolicy.find_by(layer: "execution").provider).to eq("muse")

    http.get "/admin/ai_connections"
    expect(http.last_response.body.include?("未連携")).to eq(true)
  end
end

test("layer policy pages link to the connections page") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/layer_policies"
    expect(http.last_response.body.include?("/admin/ai_connections")).to eq(true)

    http.get "/admin/layer_policies/coordination/edit"
    expect(http.last_response.body.include?("/admin/ai_connections")).to eq(true)
  end
end

test("auth code params are filtered from logs") do |db:|
  filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  %w[auth_code verification_uri user_code encrypted_challenge encrypted_input_code].each do |key|
    filtered = filter.filter({ key => "SECRET-VALUE-1", "nested" => { key => "SECRET-VALUE-2" } })
    expect(filtered[key]).to eq("[FILTERED]")
    expect(filtered["nested"][key]).to eq("[FILTERED]")
  end
end

test("CSRF: connections POST without token is rejected") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "claude", worker_role: "control")

  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.post "/admin/ai_connections/login", { provider: "codex", worker_role: "control" }
      expect(http.last_response.status).to eq(422)

      http.post "/admin/ai_connections/#{session.uuid}/cancel"
      expect(http.last_response.status).to eq(422)
      expect(session.reload.cancel_requested).to eq(false)
    end
  end
end

test("CSRF: connections POST with form token succeeds") do |http:|
  AdminTestSupport.as_admin(http) do
    AdminTestSupport.with_forgery_protection do
      http.get "/admin/ai_connections"
      body = http.last_response.body
      # Per-form tokens are tied to the action URL, so extract the token from
      # the exact claude/control login form we are about to submit.
      form = body[/<form[^>]*action="\/admin\/ai_connections\/login\?provider=claude[^"]*"[^>]*>.*?<\/form>/m, 0]
      expect(form.nil?).to eq(false)
      token = form[/name="authenticity_token" value="([^"]+)"/, 1]
      expect(token.nil?).to eq(false)

      http.post "/admin/ai_connections/login?provider=claude&worker_role=control",
        { authenticity_token: token }
      expect(http.last_response.status).to eq(302)
      expect(AiAuthSession.active.find_by(provider: "claude", worker_role: "control").nil?).to eq(false)
    end
  end
end

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

test("index with no history renders without nil errors") do |http:|
  AdminTestSupport.as_admin(http) do
    expect(AiAuthSession.count).to eq(0)
    expect(AiConnection.count).to eq(0)

    http.get "/admin/ai_connections"

    # Regression: nil sessions/snapshots must not raise NoMethodError on
    # `active?`; every pair renders its start/check actions instead.
    expect(http.last_response.status).to eq(200)
    body = http.last_response.body
    expect(body.include?("連携開始")).to eq(true)
    expect(body.include?("状態確認")).to eq(true)
    expect(body.include?("未確認")).to eq(true)
  end
end

test("index carries no-store cache and same-origin referrer policy") do |http:|
  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"

    expect(http.last_response.headers["Cache-Control"]).to eq("no-store")
    # same-origin (not no-referrer): IAB browsers send `Origin: null` under
    # no-referrer and Rails rejects POSTs with InvalidAuthenticityToken.
    # CSRF origin checks stay enabled; external auth links keep
    # rel=noopener noreferrer in the view (covered below).
    expect(http.last_response.headers["Referrer-Policy"]).to eq("same-origin")
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
    # JS polling without meta refresh (input-safe): reload is deferred only
    # while a code input has a value or focus; empty/unfocused still reloads
    # so deadlines and other providers stay fresh. Submit resumes polling
    # and a manual link is always available.
    expect(body.include?('http-equiv="refresh"')).to eq(false)
    expect(body.include?("location.reload")).to eq(true)
    expect(body.include?('input[name="auth_code"]')).to eq(true)
    expect(body.include?("activeElement")).to eq(true)
    expect(body.include?("el.value")).to eq(true)
    expect(body.include?("submitted")).to eq(true)
    expect(body.include?("更新する")).to eq(true)
    expect(body.include?("入力中・入力済みは入力を保護するため自動更新を延期")).to eq(true)
    expect(body.include?("未入力のままなら自動更新")).to eq(true)
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

test("challenge URL renders as a short safe label, not the secret query") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "codex", worker_role: "execution")
  session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/device/test-link?secret=query-999",
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
    expect(body.include?("Codex公式認証画面を開く")).to eq(true)
    # The secret URL must not become the visible link text.
    expect(body.include?(">https://example.invalid/device/test-link")).to eq(false)
    # Ciphertext itself never renders.
    expect(body.include?(session.reload.encrypted_challenge.to_s[0, 20])).to eq(false)
  end
end

test("code input renders once, keeps #state, then shows received") do |http:|
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
    body = http.last_response.body
    expect(body.include?("auth_code")).to eq(true)
    expect(body.include?("Claude公式認証画面を開く")).to eq(true)
    expect(body.include?("#state")).to eq(true)
    expect(body.include?("#以降を取り除かない")).to eq(true)
    # Submitted (not typing) codes are encrypted at rest; no pre-submit autosave.
    expect(body.include?("送信されたコードは暗号化して一時保存")).to eq(true)
    expect(body.include?("入力中は暗号化")).to eq(false)
    expect(body.include?("保存されません")).to eq(false)
    # Footer states the accurate long-term secret policy (temporary
    # challenges are shown; long-term tokens/API keys never are).
    expect(body.include?("長期トークン・APIキーは表示しません")).to eq(true)
    expect(body.include?("認証内容）は表示しません")).to eq(false)

    http.post "/admin/ai_connections/#{needing.uuid}/code", { auth_code: "  input-secret-7#state-9 " }
    expect(http.last_response.status).to eq(302)
    expect(needing.reload.input_code_present?).to eq(true)
    expect(needing.reload.input_submitted_at.nil?).to eq(false)
    expect(needing.encrypted_input_code.include?("input-secret-7")).to eq(false)
    stored = AiAuth::SecretBox.default.decrypt(needing.reload.encrypted_input_code)
    expect(stored).to eq("input-secret-7#state-9")

    # Second submit is rejected and the form becomes "received".
    http.post "/admin/ai_connections/#{needing.uuid}/code", { auth_code: "second-try" }
    expect(http.last_response.status).to eq(302)
    http.get "/admin/ai_connections"
    after = http.last_response.body
    expect(after.include?("受付済み")).to eq(true)
    expect(after.include?("auth_code_#{needing.uuid}")).to eq(false)
  end
end

test("cancel from the UI finishes queued rows so restart works") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "muse", worker_role: "control")

  AdminTestSupport.as_admin(http) do
    http.post "/admin/ai_connections/#{session.uuid}/cancel"
    expect(http.last_response.status).to eq(302)
    expect(session.reload.status).to eq("cancelled")

    # The slot is free: a fresh login starts a new session.
    http.post "/admin/ai_connections/login", { provider: "muse", worker_role: "control" }
    expect(http.last_response.status).to eq(302)
    expect(AiAuthSession.active.find_by(provider: "muse", worker_role: "control").nil?).to eq(false)
  end
end

test("cancel flags running rows and hides input immediately") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    status: "waiting",
    claim_token: SecureRandom.uuid,
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://claude.ai/oauth/cancel-hide",
        "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  AdminTestSupport.as_admin(http) do
    http.post "/admin/ai_connections/#{session.uuid}/cancel"
    expect(http.last_response.status).to eq(302)
    expect(session.reload.cancel_requested).to eq(true)
    expect(session.reload.status).to eq("waiting")

    http.get "/admin/ai_connections"
    body = http.last_response.body
    expect(body.include?("キャンセルを受け付けました")).to eq(true)
    expect(body.include?("非表示")).to eq(true)
    expect(body.include?("auth_code_#{session.uuid}")).to eq(false)
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
    body = http.last_response.body
    expect(body.include?("接続済み")).to eq(false)
    expect(body.include?("期限切れ")).to eq(true)
    expect(body.include?("状態確認")).to eq(true)
    expect(body.include?("連携開始")).to eq(true)
  end
end

test("terminal failure without snapshot still shows safe guidance and retry") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_status(provider: "muse", worker_role: "control")
  session.update_columns(status: "failed", result_state: nil,
                         result_error_code: "runtime_unavailable",
                         finished_at: Time.current, updated_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"
    body = http.last_response.body

    expect(body.include?("失敗")).to eq(true)
    expect(body.include?("ランタイム")).to eq(true)
    expect(body.include?("状態確認")).to eq(true)
    expect(body.include?("連携開始")).to eq(true)
    expect(body.include?("runtime_unavailable")).to eq(false)
  end
end

test("cancelled terminal stays visible with retry actions") do |http:|
  session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: "codex", worker_role: "execution")
  session.update_columns(status: "cancelled", result_state: "cancelled",
                         result_error_code: "cancelled",
                         finished_at: Time.current, updated_at: Time.current)

  AdminTestSupport.as_admin(http) do
    http.get "/admin/ai_connections"
    body = http.last_response.body

    expect(body.include?("取消")).to eq(true)
    expect(body.include?("再試行")).to eq(true)
    expect(body.include?("状態確認")).to eq(true)
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

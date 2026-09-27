# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

def request_service(sink: nil)
  AiAuth::RequestService.new(event_sink: sink || WorkflowFakes::FakeEventSink.new)
end

test("double login submit returns the existing active session") do |db:|
  expect(db.transaction_open?).to eq(true)
  sink = WorkflowFakes::FakeEventSink.new
  service = request_service(sink: sink)

  first = service.request_login(provider: "claude", worker_role: "control")
  second = service.request_login(provider: "claude", worker_role: "control")

  expect(second.uuid).to eq(first.uuid)
  expect(AiAuthSession.active.where(provider: "claude", worker_role: "control").count).to eq(1)
  expect(first.operation).to eq("login")
  expect(first.status).to eq("queued")
  expect(first.expires_at > Time.current).to eq(true)
end

test("login and status share one active slot per provider and role") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  login = service.request_login(provider: "codex", worker_role: "execution")
  status = service.request_status(provider: "codex", worker_role: "execution")

  expect(status.uuid).to eq(login.uuid)
  expect(AiAuthSession.active.count).to eq(1)
end

test("different roles do not block each other") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  control = service.request_login(provider: "muse", worker_role: "control")
  execution = service.request_login(provider: "muse", worker_role: "execution")

  expect(control.uuid == execution.uuid).to eq(false)
  expect(AiAuthSession.active.count).to eq(2)
end

test("unique constraint survives a race: second insert returns the first row") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service
  first = service.request_login(provider: "claude", worker_role: "execution")

  raised = nil
  begin
    AiAuthSession.create!(uuid: SecureRandom.uuid, provider: "claude", worker_role: "execution",
                          operation: "login", status: "queued", expires_at: 10.minutes.from_now)
  rescue ActiveRecord::RecordNotUnique => e
    raised = e
  end
  expect(raised.nil?).to eq(false)

  second = service.request_login(provider: "claude", worker_role: "execution")
  expect(second.uuid).to eq(first.uuid)
end

test("invalid provider and role are rejected without rows or jobs") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  %w[bad_provider bad_role].each do |_|
    # placeholder to keep the test name honest; real assertions below
  end

  begin
    service.request_login(provider: "gpt", worker_role: "control")
    raise "expected InvalidRequest"
  rescue AiAuth::RequestService::InvalidRequest
    nil
  end
  begin
    service.request_login(provider: "claude", worker_role: "web")
    raise "expected InvalidRequest"
  rescue AiAuth::RequestService::InvalidRequest
    nil
  end

  expect(AiAuthSession.count).to eq(0)
  expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(0)
end

test("login enqueues the role queue, status enqueues the role queue") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  login = service.request_login(provider: "claude", worker_role: "control")
  status_session = service.request_status(provider: "codex", worker_role: "execution")

  login_job = SolidQueue::Job.find_by(class_name: "AiAuthJob", queue_name: "ai_auth_control")
  execution_job = SolidQueue::Job.find_by(class_name: "AiAuthJob", queue_name: "ai_auth_execution")

  expect(login_job.nil?).to eq(false)
  expect(execution_job.nil?).to eq(false)
  expect(login_job.arguments["arguments"].first).to eq(login.uuid)
  expect(execution_job.arguments["arguments"].first).to eq(status_session.uuid)
end

test("cancel finishes queued rows immediately and frees the slot") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    encrypted_challenge: AiAuth::SecretBox.default.encrypt({ "verification_uri" => "https://example.invalid/q" }),
    updated_at: Time.current
  )
  service.cancel(session_uuid: session.uuid)

  reloaded = session.reload
  expect(reloaded.status).to eq("cancelled")
  expect(reloaded.result_state).to eq("cancelled")
  expect(reloaded.encrypted_challenge).to eq(nil)
  expect(reloaded.encrypted_input_code).to eq(nil)

  # The active-slot lock is released: the next operation starts fresh.
  fresh = service.request_login(provider: "claude", worker_role: "control")
  expect(fresh.uuid == session.uuid).to eq(false)
  expect(fresh.status).to eq("queued")
end

test("cancel flags running rows and is idempotent on terminal rows") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(status: "running", claim_token: SecureRandom.uuid,
                         claimed_at: Time.current, heartbeat_at: Time.current,
                         updated_at: Time.current)
  service.cancel(session_uuid: session.uuid)

  reloaded = session.reload
  expect(reloaded.cancel_requested).to eq(true)
  expect(reloaded.status).to eq("running")

  reloaded.update!(status: "succeeded", finished_at: Time.current)
  again = service.cancel(session_uuid: session.uuid)
  expect(again.status).to eq("succeeded")
end

test("expired actives recover so the next operation can proceed") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  stale = service.request_login(provider: "codex", worker_role: "control")
  stale.update_columns(expires_at: 1.minute.ago, updated_at: Time.current)
  expect(stale.reload.active?).to eq(true)

  fresh = service.request_login(provider: "codex", worker_role: "control")

  expect(fresh.uuid == stale.uuid).to eq(false)
  expect(stale.reload.status).to eq("expired")
  expect(stale.encrypted_challenge).to eq(nil)
  expect(stale.encrypted_input_code).to eq(nil)
  expect(fresh.status).to eq("queued")
end

test("stale claimed sessions without heartbeat recover, queued rows keep waiting") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  claimed = service.request_login(provider: "muse", worker_role: "control")
  claimed.update_columns(status: "running", claim_token: SecureRandom.uuid,
                         claimed_at: 10.minutes.ago, heartbeat_at: 10.minutes.ago,
                         updated_at: Time.current)
  queued = service.request_status(provider: "muse", worker_role: "execution")
  queued.update_columns(created_at: 10.minutes.ago, updated_at: Time.current)

  service.recover_expired!

  expect(claimed.reload.status).to eq("expired")
  # Queued rows with no worker stay waiting until their deadline, never success.
  expect(queued.reload.status).to eq("queued")
end

test("code submit stores ciphertext only and rejects bad input") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/auth", "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  service.submit_code(session_uuid: session.uuid, code: "  secret-code-123 ")
  reloaded = session.reload
  expect(reloaded.input_code_present?).to eq(true)
  expect(reloaded.input_submitted_at.nil?).to eq(false)
  expect(reloaded.encrypted_input_code.include?("secret-code-123")).to eq(false)
  expect(reloaded.challenge["input_required"]).to eq(true)
  # Decrypts to the stripped single line.
  expect(AiAuth::SecretBox.default.decrypt(reloaded.encrypted_input_code)).to eq("secret-code-123")

  empty_session = service.request_login(provider: "claude", worker_role: "execution")
  empty_session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/auth", "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )
  begin
    service.submit_code(session_uuid: empty_session.uuid, code: "   ")
    raise "expected InvalidRequest"
  rescue AiAuth::RequestService::InvalidRequest
    nil
  end
end

test("code submit keeps #state, rejects multiline/control/non-string") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://claude.ai/oauth/test", "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  service.submit_code(session_uuid: session.uuid, code: "  authcode123#state456  ")
  stored = AiAuth::SecretBox.default.decrypt(session.reload.encrypted_input_code)
  expect(stored).to eq("authcode123#state456")

  bad_session = service.request_login(provider: "codex", worker_role: "control")
  bad_session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/auth", "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )
  ["line1\nline2", "a\rb", "a\x00b", "a\x01b", "a\x7Fb"].each do |bad|
    begin
      service.submit_code(session_uuid: bad_session.uuid, code: bad)
      raise "expected InvalidRequest for #{bad.inspect}"
    rescue AiAuth::RequestService::InvalidRequest => e
      expect(e.message.include?("1行")).to eq(true)
    end
  end
  [nil, 123, { "code" => "x" }].each do |bad|
    begin
      service.submit_code(session_uuid: bad_session.uuid, code: bad)
      raise "expected InvalidRequest for #{bad.inspect}"
    rescue AiAuth::RequestService::InvalidRequest
      nil
    end
  end
  expect(bad_session.reload.input_code_present?).to eq(false)
end

test("code submit rejects double POST after receipt") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/auth", "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  service.submit_code(session_uuid: session.uuid, code: "first-code-1")
  expect(session.reload.input_submitted_at.nil?).to eq(false)

  begin
    service.submit_code(session_uuid: session.uuid, code: "second-code-2")
    raise "expected InvalidRequest"
  rescue AiAuth::RequestService::InvalidRequest => e
    expect(e.message.include?("受付済み")).to eq(true)
  end
  # First code is preserved, not overwritten.
  expect(AiAuth::SecretBox.default.decrypt(session.reload.encrypted_input_code)).to eq("first-code-1")
end

test("code submit is rejected after cancel is requested") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    status: "waiting",
    claim_token: SecureRandom.uuid,
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/auth", "user_code" => nil, "input_required" => true }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )
  service.cancel(session_uuid: session.uuid)
  expect(session.reload.cancel_requested).to eq(true)

  begin
    service.submit_code(session_uuid: session.uuid, code: "late-code-1")
    raise "expected InvalidRequest"
  rescue AiAuth::RequestService::InvalidRequest => e
    expect(e.message.include?("キャンセル")).to eq(true)
  end
end

test("code submit is rejected when no input is required") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "codex", worker_role: "control")
  session.update_columns(
    status: "waiting",
    encrypted_challenge: AiAuth::SecretBox.default.encrypt(
      { "verification_uri" => "https://example.invalid/device", "user_code" => "AB-12", "input_required" => false }
    ),
    challenge_updated_at: Time.current,
    updated_at: Time.current
  )

  begin
    service.submit_code(session_uuid: session.uuid, code: "whatever")
    raise "expected InvalidRequest"
  rescue AiAuth::RequestService::InvalidRequest => e
    expect(e.message.include?("不要")).to eq(true)
  end
  expect(session.reload.input_code_present?).to eq(false)
end

test("session inspection never exposes ciphertext") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = request_service

  session = service.request_login(provider: "claude", worker_role: "control")
  session.update_columns(
    encrypted_challenge: AiAuth::SecretBox.default.encrypt({ "verification_uri" => "https://example.invalid/" }),
    encrypted_input_code: AiAuth::SecretBox.default.encrypt("code-1"),
    updated_at: Time.current
  )
  inspected = session.reload.inspect
  expect(inspected.include?("encrypted")).to eq(false)
  expect(inspected.include?("code-1")).to eq(false)
  expect(inspected.include?(session.uuid)).to eq(true)
end

# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

def request_login(provider: "claude", role: "control")
  AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: provider, worker_role: role)
end

def request_status(provider: "codex", role: "control")
  AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_status(provider: provider, worker_role: role)
end

test("status check records a worker-confirmed snapshot and clears no secrets") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_status(provider: "codex", role: "control")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    sink = WorkflowFakes::FakeEventSink.new

    result = AiAuth::WorkerService.new(runner: runner, event_sink: sink).call(session.uuid)

    expect(result.ok).to eq(true)
    expect(session.reload.status).to eq("succeeded")
    snapshot = AiConnection.find_by(provider: "codex", worker_role: "control")
    expect(snapshot.state).to eq("connected")
    expect(snapshot.checked_at.nil?).to eq(false)
    expect(snapshot.error_code).to eq(nil)
    expect(sink.kinds.include?("auth.succeeded")).to eq(true)
  end
end

test("status maps disconnected and unavailable, sanitizes unsafe error text") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_status(provider: "muse", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "muse" => { "state" => "unavailable", "error_code" => "raw stderr token=SECRET" } }
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(true)
    expect(session.reload.status).to eq("succeeded")
    snapshot = AiConnection.find_by(provider: "muse", worker_role: "execution")
    expect(snapshot.state).to eq("unavailable")
    expect(snapshot.error_code).to eq("provider_error")
    expect(snapshot.error_code.include?("SECRET")).to eq(false)
  end
end

test("login consumes a submitted code exactly once and wipes secrets") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "claude", role: "control")
    # Full flow in one thread: the fake publishes a challenge, the ops
    # service submits the code like the admin UI, then the worker consumes
    # it exactly once through the input callback.
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        on_challenge.call({
          "verification_uri" => "https://claude.ai/oauth/authorize?code=test-challenge",
          "user_code" => nil,
          "input_required" => true
        })
        expect(session.reload.status).to eq("waiting")
        expect(session.encrypted_challenge.include?("claude.ai")).to eq(false)

        AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
          .submit_code(session_uuid: session.uuid, code: "claude-secret-code")

        first = input.call
        second = input.call
        expect(first).to eq("claude-secret-code")
        expect(second).to eq(nil)
        { "state" => "connected", "error_code" => nil }
      end
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(true)
    reloaded = session.reload
    expect(reloaded.status).to eq("succeeded")
    expect(reloaded.result_state).to eq("connected")
    expect(reloaded.encrypted_challenge).to eq(nil)
    expect(reloaded.encrypted_input_code).to eq(nil)
    # Second consumption is impossible: the code was cleared atomically.
    expect(reloaded.consume_input_code!).to eq(nil)

    snapshot = AiConnection.find_by(provider: "claude", worker_role: "control")
    expect(snapshot.state).to eq("connected")
  end
end

test("device approval without input succeeds and stores ciphertext only") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "codex", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.device_approval

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(true)
    expect(session.reload.status).to eq("succeeded")
    expect(session.encrypted_challenge).to eq(nil)
    snapshot = AiConnection.find_by(provider: "codex", worker_role: "execution")
    expect(snapshot.state).to eq("connected")
  end
end

test("cancel during login reports cancelled and wipes secrets without snapshot") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "muse", role: "control")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        on_challenge.call({
          "verification_uri" => "https://example.invalid/device/cancel-test",
          "user_code" => "WXYZ-9999",
          "input_required" => false
        })
        expect(session.reload.challenge.nil?).to eq(false)
        AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new).cancel(session_uuid: session.uuid)
        expect(cancelled.call).to eq(true)
        { "state" => "cancelled", "error_code" => "cancelled" }
      end
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:cancelled)
    reloaded = session.reload
    expect(reloaded.status).to eq("cancelled")
    expect(reloaded.encrypted_challenge).to eq(nil)
    expect(reloaded.encrypted_input_code).to eq(nil)
    expect(AiConnection.find_by(provider: "muse", worker_role: "control")).to eq(nil)
  end
end

test("duplicate delivery never double-runs a claimed session") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_status(provider: "claude", role: "control")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "claude" => { "state" => "connected", "error_code" => nil } }
    )
    service = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new)

    first = service.call(session.uuid)
    second = service.call(session.uuid)

    expect(first.ok).to eq(true)
    expect(second.ok).to eq(false)
    expect(second.code).to eq(:duplicate_delivery)
    expect(runner.status_calls.size).to eq(1)
  end
end

test("role mismatch fails safe without running the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "control")
    runner = AiAuthTestSupport::FakeAuthRunner.immediate

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:role_mismatch)
    expect(runner.login_calls.size).to eq(0)
    expect(session.reload.status).to eq("failed")
    expect(session.result_error_code).to eq("role_mismatch")
    expect(AiConnection.find_by(provider: "claude", worker_role: "control")).to eq(nil)
  end
end

test("missing worker role fails safe without running the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role(nil) do
    session = request_status(provider: "claude", role: "control")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "claude" => { "state" => "connected", "error_code" => nil } }
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:role_mismatch)
    expect(runner.status_calls.size).to eq(0)
  end
end

test("expired sessions never run the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "claude", role: "control")
    session.update_columns(expires_at: 1.second.ago, updated_at: Time.current)
    runner = AiAuthTestSupport::FakeAuthRunner.immediate

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.code).to eq(:expired)
    expect(runner.login_calls.size).to eq(0)
    expect(session.reload.status).to eq("expired")
  end
end

test("old jobs cannot overwrite a newer snapshot (fencing)") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    first = request_status(provider: "codex", role: "control")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    service = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new)
    expect(service.call(first.uuid).ok).to eq(true)
    expect(AiConnection.find_by(provider: "codex", worker_role: "control").state).to eq("connected")

    second = request_status(provider: "codex", role: "control")
    failing = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "failed", "error_code" => "provider_error" } }
    )
    expect(AiAuth::WorkerService.new(runner: failing, event_sink: WorkflowFakes::FakeEventSink.new).call(second.uuid).ok).to eq(true)
    expect(AiConnection.find_by(provider: "codex", worker_role: "control").state).to eq("failed")

    # Replay the old claim directly: fencing must refuse the stale write.
    stale = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new)
    replay = stale.send(:settle, first.id, first.reload.claim_token,
                        status: "succeeded", result_state: "connected",
                        result_error: nil, snapshot: true)
    expect(replay.code).to eq(:duplicate_delivery)
    expect(AiConnection.find_by(provider: "codex", worker_role: "control").state).to eq("failed")
  end
end

test("invalid challenge URLs are rejected and the session fails safe") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "claude", role: "control")
    bad = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        begin
          on_challenge.call({ "verification_uri" => "http://evil.invalid/phish", "user_code" => "X", "input_required" => true })
        rescue StandardError
          next({ "state" => "failed", "error_code" => "callback_failed" })
        end
        { "state" => "connected", "error_code" => nil }
      end
    )

    result = AiAuth::WorkerService.new(runner: bad, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(session.reload.status).to eq("failed")
    expect(session.encrypted_challenge).to eq(nil)
    snapshot = AiConnection.find_by(provider: "claude", worker_role: "control")
    expect(snapshot.state).to eq("failed")
    expect(snapshot.error_code).to eq("callback_failed")
  end
end

test("runtime exceptions become a sanitized failure, never raw text") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "claude", role: "control")
    exploding = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: ->(*) { raise StandardError, "cli blew up with token=SECRET-123" }
    )

    result = AiAuth::WorkerService.new(runner: exploding, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    reloaded = session.reload
    expect(reloaded.status).to eq("failed")
    expect(reloaded.result_error_code).to eq("provider_error")
    expect(reloaded.inspect.include?("SECRET")).to eq(false)
  end
end

test("missing runtime fails as unavailable without a production stub") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_status(provider: "claude", role: "control")

    result = AiAuth::WorkerService.new(runner_proc: -> { nil },
                                       event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(session.reload.status).to eq("failed")
    expect(session.result_error_code).to eq("runtime_unavailable")
  end
end

test("heartbeat writes are throttled to one per 10 seconds") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "claude", role: "control")
    base = Time.current
    fake_clock = Class.new do
      attr_accessor :now_time
      def current = now_time
      def now = now_time
    end.new
    fake_clock.now_time = base

    service = AiAuth::WorkerService.new(runner: AiAuthTestSupport::FakeAuthRunner.immediate,
                                        event_sink: WorkflowFakes::FakeEventSink.new, clock: fake_clock)
    claimed = service.send(:claim, session.uuid)
    expect(claimed.is_a?(Array)).to eq(true)
    session_id, claim_token = claimed[0], claimed[1]

    session.update_columns(heartbeat_at: base, updated_at: base)
    service.instance_variable_set(:@last_heartbeat_write, base)

    fake_clock.now_time = base + 5
    service.send(:maybe_heartbeat, session_id, claim_token)
    expect(session.reload.heartbeat_at.to_i).to eq(base.to_i)

    fake_clock.now_time = base + 11
    service.send(:maybe_heartbeat, session_id, claim_token)
    expect(session.reload.heartbeat_at.to_i).to eq((base + 11).to_i)
  end
end

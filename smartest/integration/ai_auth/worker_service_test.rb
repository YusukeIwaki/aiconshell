# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

def request_login(provider: "claude", role: "execution")
  AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_login(provider: provider, worker_role: role)
end

def request_status(provider: "codex", role: "execution")
  AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    .request_status(provider: provider, worker_role: role)
end

# Legacy control rows predate the single-worker switch (issue 20). The
# request service rejects new control operations, so these rows are built
# directly; the model still accepts them for revocation.
def legacy_control_session(provider: "claude", operation: "login")
  AiAuthSession.create!(
    uuid: SecureRandom.uuid, provider: provider, worker_role: "control",
    operation: operation, status: "queued", expires_at: 10.minutes.from_now
  )
end

test("status check records a worker-confirmed snapshot and clears no secrets") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_status(provider: "codex", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    sink = WorkflowFakes::FakeEventSink.new

    result = AiAuth::WorkerService.new(runner: runner, event_sink: sink).call(session.uuid)

    expect(result.ok).to eq(true)
    expect(session.reload.status).to eq("succeeded")
    snapshot = AiConnection.find_by(provider: "codex", worker_role: "execution")
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
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
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

    snapshot = AiConnection.find_by(provider: "claude", worker_role: "execution")
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
  with_worker_role("execution") do
    session = request_login(provider: "muse", role: "execution")
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
    expect(AiConnection.find_by(provider: "muse", worker_role: "execution")).to eq(nil)
  end
end

test("duplicate delivery never double-runs a claimed session") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_status(provider: "claude", role: "execution")
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

test("legacy control sessions fail safe without running the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = legacy_control_session(provider: "claude")
    runner = AiAuthTestSupport::FakeAuthRunner.immediate

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:role_mismatch)
    expect(runner.login_calls.size).to eq(0)
    expect(session.reload.status).to eq("failed")
    expect(session.result_error_code).to eq("role_mismatch")
    expect(AiConnection.find_by(provider: "claude", worker_role: "control")).to eq(nil)
    # Control state is never copied to the execution snapshot.
    expect(AiConnection.find_by(provider: "claude", worker_role: "execution")).to eq(nil)
  end
end

test("execution sessions reject the wrong worker without running the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    session = request_login(provider: "claude", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.immediate

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:role_mismatch)
    expect(runner.login_calls.size).to eq(0)
    expect(session.reload.status).to eq("failed")
    expect(session.result_error_code).to eq("role_mismatch")
  end
end

test("missing worker role fails safe without running the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role(nil) do
    session = request_status(provider: "claude", role: "execution")
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
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
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
  with_worker_role("execution") do
    first = request_status(provider: "codex", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    service = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new)
    expect(service.call(first.uuid).ok).to eq(true)
    expect(AiConnection.find_by(provider: "codex", worker_role: "execution").state).to eq("connected")

    second = request_status(provider: "codex", role: "execution")
    failing = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "failed", "error_code" => "provider_error" } }
    )
    expect(AiAuth::WorkerService.new(runner: failing, event_sink: WorkflowFakes::FakeEventSink.new).call(second.uuid).ok).to eq(true)
    expect(AiConnection.find_by(provider: "codex", worker_role: "execution").state).to eq("failed")

    # Replay the old claim directly: fencing must refuse the stale write.
    stale = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new)
    replay = stale.send(:settle, first.id, first.reload.claim_token,
                        status: "succeeded", result_state: "connected",
                        result_error: nil, snapshot: true)
    expect(replay.code).to eq(:duplicate_delivery)
    expect(AiConnection.find_by(provider: "codex", worker_role: "execution").state).to eq("failed")
  end
end

test("invalid challenge URLs are rejected and the session fails safe") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
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
    snapshot = AiConnection.find_by(provider: "claude", worker_role: "execution")
    expect(snapshot.state).to eq("failed")
    expect(snapshot.error_code).to eq("callback_failed")
  end
end

test("runtime exceptions become a sanitized failure, never raw text") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
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
  with_worker_role("execution") do
    session = request_status(provider: "claude", role: "execution")

    result = AiAuth::WorkerService.new(runner_proc: -> { nil },
                                       event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(session.reload.status).to eq("failed")
    expect(session.result_error_code).to eq("runtime_unavailable")
  end
end

test("heartbeat writes are throttled to one per 10 seconds") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
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

test("settle converts stale connected to cancelled when cancel lands just before write") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        # Simulate a cancel arriving after the runtime produced connected
        # but before the final write: flag the row, then report connected.
        AiAuthSession.where(id: session.id).update_all(cancel_requested: true, updated_at: Time.current)
        { "state" => "connected", "error_code" => nil }
      end
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:cancelled)
    reloaded = session.reload
    expect(reloaded.status).to eq("cancelled")
    expect(reloaded.result_state).to eq("cancelled")
    expect(reloaded.encrypted_challenge).to eq(nil)
    expect(reloaded.encrypted_input_code).to eq(nil)
    expect(AiConnection.find_by(provider: "claude", worker_role: "execution")).to eq(nil)
  end
end

test("settle converts stale connected to expired when deadline lands just before write") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "codex", role: "execution")
    base = Time.current
    fake_clock = Class.new do
      attr_accessor :now_time
      def current = now_time
      def now = now_time
    end.new
    fake_clock.now_time = base

    runner = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        # Advance the clock past the deadline before the final write.
        fake_clock.now_time = base + AiAuth::RequestService::LOGIN_TIMEOUT_SECONDS + 5
        { "state" => "connected", "error_code" => nil }
      end
    )
    service = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new, clock: fake_clock)

    result = service.call(session.uuid)

    expect(result.code).to eq(:expired)
    reloaded = session.reload
    expect(reloaded.status).to eq("expired")
    expect(reloaded.encrypted_challenge).to eq(nil)
    expect(AiConnection.find_by(provider: "codex", worker_role: "execution")).to eq(nil)
  end
end

test("settle re-evaluates now after the row lock, so lock-wait expiry wins") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
    token = SecureRandom.uuid
    base = Time.current
    session.update_columns(status: "running", claim_token: token,
                           claimed_at: base, heartbeat_at: base,
                           expires_at: base + 10, updated_at: base)
    fake_clock = Class.new do
      attr_accessor :now_time
      def current = now_time
      def now = now_time
    end.new
    fake_clock.now_time = base

    service = AiAuth::WorkerService.new(runner: AiAuthTestSupport::FakeAuthRunner.immediate,
                                        event_sink: WorkflowFakes::FakeEventSink.new,
                                        clock: fake_clock)
    # Simulate the deadline passing while waiting for the row lock: advance
    # the clock when the lock is acquired. Post-lock evaluation must see
    # expiry; a pre-lock timestamp would have seen `base` and saved connected.
    original_lock = AiAuthSession.method(:lock)
    AiAuthSession.define_singleton_method(:lock) do |*args, **kwargs, &blk|
      fake_clock.now_time = base + 11
      original_lock.call(*args, **kwargs, &blk)
    end
    begin
      result = service.send(:settle, session.id, token,
                            status: "succeeded", result_state: "connected",
                            result_error: nil, snapshot: true)
    ensure
      AiAuthSession.define_singleton_method(:lock, original_lock)
    end

    expect(result.code).to eq(:expired)
    reloaded = session.reload
    expect(reloaded.status).to eq("expired")
    expect(reloaded.encrypted_challenge).to eq(nil)
    expect(AiConnection.find_by(provider: "claude", worker_role: "execution")).to eq(nil)
  end
end

test("unknown error codes collapse to provider_error and never persist raw text") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_status(provider: "muse", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "muse" => { "state" => "failed", "error_code" => "secret_sentinel_abc" } }
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(true)
    reloaded = session.reload
    expect(reloaded.result_error_code).to eq("provider_error")
    snapshot = AiConnection.find_by(provider: "muse", worker_role: "execution")
    expect(snapshot.error_code).to eq("provider_error")
    expect(snapshot.error_code.include?("sentinel")).to eq(false)
  end
end

test("input consume keeps submitted stamp while clearing ciphertext once") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_login(provider: "claude", role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      login_behavior: lambda do |provider:, timeout:, on_challenge:, input:, cancelled:|
        on_challenge.call({
          "verification_uri" => "https://claude.ai/oauth/authorize?code=stamp-test",
          "user_code" => nil,
          "input_required" => true
        })
        AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
          .submit_code(session_uuid: session.uuid, code: "code-with#state-keep")
        first = input.call
        stamp_after_first = session.reload.input_submitted_at
        second = input.call
        expect(first).to eq("code-with#state-keep")
        expect(second).to eq(nil)
        expect(stamp_after_first.nil?).to eq(false)
        expect(session.reload.input_submitted_at.nil?).to eq(false)
        expect(session.reload.encrypted_input_code).to eq(nil)
        { "state" => "connected", "error_code" => nil }
      end
    )

    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowFakes::FakeEventSink.new).call(session.uuid)

    expect(result.ok).to eq(true)
    expect(session.reload.input_submitted_at.nil?).to eq(false)
    expect(session.reload.encrypted_input_code).to eq(nil)
  end
end

test("snapshot fencing refuses an old write after a newer result") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    first = request_status(provider: "codex", role: "execution")
    connected = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    expect(AiAuth::WorkerService.new(runner: connected, event_sink: WorkflowFakes::FakeEventSink.new).call(first.uuid).ok).to eq(true)

    second = request_status(provider: "codex", role: "execution")
    failing = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "failed", "error_code" => "spawn_failed" } }
    )
    expect(AiAuth::WorkerService.new(runner: failing, event_sink: WorkflowFakes::FakeEventSink.new).call(second.uuid).ok).to eq(true)
    snapshot = AiConnection.find_by(provider: "codex", worker_role: "execution")
    expect(snapshot.state).to eq("failed")
    expect(snapshot.last_session_id).to eq(second.id)

    # A delayed write from the older session must not overwrite.
    service = AiAuth::WorkerService.new(runner: connected, event_sink: WorkflowFakes::FakeEventSink.new)
    service.send(:update_snapshot, first.reload, "connected", nil, Time.current)
    after = AiConnection.find_by(provider: "codex", worker_role: "execution")
    expect(after.state).to eq("failed")
    expect(after.last_session_id).to eq(second.id)
  end
end

test("concurrent first inserts from separate connections do not raise and fence by session") do |db:|
  expect(db.transaction_open?).to eq(true)
  provider = "muse"
  role = "execution"
  # Threads commit outside the test transaction, so clean committed rows via
  # a separate connection before and after (the test transaction only holds
  # AiAuthSession rows, which threads never query).
  cleanup = lambda do
    cleaner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        AiConnection.where(provider: provider, worker_role: role).delete_all
      end
    end
    cleaner.join
  end
  cleanup.call
  begin
    first = AiAuthSession.create!(uuid: SecureRandom.uuid, provider: provider, worker_role: role,
                                 operation: "status_check", status: "succeeded",
                                 expires_at: 10.minutes.from_now, finished_at: Time.current)
    second = AiAuthSession.create!(uuid: SecureRandom.uuid, provider: provider, worker_role: role,
                                  operation: "status_check", status: "succeeded",
                                  expires_at: 10.minutes.from_now, finished_at: Time.current)
    expect(second.id > first.id).to eq(true)

    errors = Queue.new
    ready = Queue.new
    start = Queue.new
    workers = [
      [[first.id, first.uuid], "connected", nil],
      [[second.id, second.uuid], "failed", "provider_error"]
    ].map do |(attrs, state, err)|
      Thread.new do
        begin
          # Each thread checks out its own real DB connection from the pool.
          ActiveRecord::Base.connection_pool.with_connection do
            # Threads use only in-memory fencing keys; the session rows live
            # in the uncommitted test transaction and are never queried here.
            fake = AiAuthSession.new(provider: provider, worker_role: role,
                                     uuid: attrs[1], id: attrs[0])
            ready << true
            start.pop
            service = AiAuth::WorkerService.new(
              runner: AiAuthTestSupport::FakeAuthRunner.immediate,
              event_sink: WorkflowFakes::FakeEventSink.new)
            service.send(:update_snapshot, fake, state, err, Time.current)
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          errors << e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    workers.each(&:join)
    raise errors.pop unless errors.empty?

    # One row; the newer session wins regardless of write order (fencing).
    # The main connection (READ COMMITTED) sees the threads' committed rows.
    rows = AiConnection.where(provider: provider, worker_role: role).to_a
    expect(rows.size).to eq(1)
    expect(rows.first.last_session_id).to eq(second.id)
    expect(rows.first.state).to eq("failed")
    expect(rows.first.error_code).to eq("provider_error")
  ensure
    cleanup.call
  end
end

test("worker emits use the execution layer; legacy control emits nothing") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = request_status(provider: "claude", role: "execution")
    sink = WorkflowFakes::FakeEventSink.new
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "claude" => { "state" => "connected", "error_code" => nil } }
    )
    AiAuth::WorkerService.new(runner: runner, event_sink: sink).call(session.uuid)
    expect(sink.events.last[:layer]).to eq("execution")
  end
  with_worker_role("execution") do
    legacy = legacy_control_session(provider: "codex", operation: "status_check")
    sink = WorkflowFakes::FakeEventSink.new
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    result = AiAuth::WorkerService.new(runner: runner, event_sink: sink).call(legacy.uuid)
    expect(result.code).to eq(:role_mismatch)
    expect(sink.events.empty?).to eq(true)
  end
end

# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

# Cutover regressions for the single-execution-worker switch (issue 20).
# Legacy control rows predate the switch; the request service rejects new
# control operations, so those rows are built directly here. The models
# still accept the control role so revocation can close them.
def legacy_control_row(provider:, status:, with_secrets: true, expired: false)
  challenge = with_secrets ? AiAuth::SecretBox.default.encrypt(
    { "verification_uri" => "https://example.invalid/legacy-auth",
      "user_code" => "LEGACY-1", "input_required" => true }
  ) : nil
  input = with_secrets ? AiAuth::SecretBox.default.encrypt("legacy-code-1#state-2") : nil
  AiAuthSession.create!(
    uuid: SecureRandom.uuid, provider: provider, worker_role: "control",
    operation: "login", status: status,
    expires_at: expired ? 1.minute.ago : 10.minutes.from_now,
    claim_token: status == "queued" ? nil : SecureRandom.uuid,
    claimed_at: status == "queued" ? nil : Time.current,
    heartbeat_at: status == "queued" ? nil : Time.current,
    encrypted_challenge: challenge,
    challenge_updated_at: with_secrets ? Time.current : nil,
    encrypted_input_code: input,
    input_updated_at: with_secrets ? Time.current : nil,
    input_submitted_at: with_secrets ? Time.current : nil
  )
end

class LegacyControlSurvivorJob < ApplicationJob
  queue_as :control

  def perform
  end
end

test("new control-targeted auth is rejected without rows or jobs") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)

  %i[request_login request_status].each do |message|
    begin
      service.public_send(message, provider: "claude", worker_role: "control")
      raise "expected InvalidRequest"
    rescue AiAuth::RequestService::InvalidRequest
      nil
    end
  end

  expect(AiAuthSession.where(worker_role: "control").count).to eq(0)
  expect(SolidQueue::Job.where(class_name: "AiAuthJob").count).to eq(0)
end

test("revocation closes legacy control sessions and wipes their secrets") do |db:|
  expect(db.transaction_open?).to eq(true)
  sink = WorkflowFakes::FakeEventSink.new
  service = AiAuth::RequestService.new(event_sink: sink)

  queued = legacy_control_row(provider: "claude", status: "queued")
  running = legacy_control_row(provider: "codex", status: "running")
  waiting = legacy_control_row(provider: "muse", status: "waiting")

  result = service.revoke_legacy_control!

  expect(result[:revoked]).to eq(3)
  [queued, running, waiting].each do |session|
    reloaded = session.reload
    expect(reloaded.status).to eq("cancelled")
    expect(reloaded.result_state).to eq("cancelled")
    expect(reloaded.result_error_code).to eq("cancelled")
    expect(reloaded.encrypted_challenge).to eq(nil)
    expect(reloaded.encrypted_input_code).to eq(nil)
    expect(reloaded.finished_at.nil?).to eq(false)
  end

  cancelled = sink.events.select { |event| event[:kind] == "auth.cancelled" }
  expect(cancelled.size).to eq(3)
  cancelled.each do |event|
    expect(event[:layer]).to eq("interaction")
    expect(event[:data][:worker_role]).to eq("control")
    payload = JSON.generate(event[:data])
    expect(payload.include?("http")).to eq(false)
    expect(payload.include?("LEGACY")).to eq(false)
    expect(payload.include?("legacy-code")).to eq(false)
  end
end

test("revocation expires past-deadline control sessions instead of cancelling") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)

  stale = legacy_control_row(provider: "claude", status: "queued", expired: true)

  result = service.revoke_legacy_control!

  expect(result[:revoked]).to eq(1)
  expect(stale.reload.status).to eq("expired")
  expect(stale.result_state).to eq("expired")
  expect(stale.encrypted_challenge).to eq(nil)
  expect(stale.encrypted_input_code).to eq(nil)
end

test("revocation keeps execution work, business records and other queues") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)

  legacy = legacy_control_row(provider: "claude", status: "waiting")
  AiAuthJob.set(queue: "ai_auth_control").perform_later(legacy.uuid)
  legacy_job = SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_control").to_a
  expect(legacy_job.size).to eq(1)

  live = service.request_login(provider: "codex", worker_role: "execution")
  live_job_count = SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_execution").count
  expect(live_job_count).to eq(1)

  task = Task.create!(title: "業務タスク", status: "inbox")
  run = TaskRun.create!(task: task, provider: "codex", status: "pending")
  policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
  LegacyControlSurvivorJob.perform_later
  survivor_count = SolidQueue::Job.where(class_name: "LegacyControlSurvivorJob", queue_name: "control").count
  expect(survivor_count).to eq(1)

  result = service.revoke_legacy_control!

  expect(result[:revoked]).to eq(1)
  expect(result[:discarded_jobs]).to eq(1)
  expect(SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_control").count).to eq(0)

  # Everything outside the legacy auth scope survives untouched.
  expect(live.reload.status).to eq("queued")
  expect(SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_execution").count).to eq(1)
  expect(task.reload.status).to eq("inbox")
  expect(Task.find_by(id: task.id).nil?).to eq(false)
  expect(run.reload.status).to eq("pending")
  expect(policy.reload.provider).to eq("codex")
  expect(SolidQueue::Job.where(class_name: "LegacyControlSurvivorJob", queue_name: "control").count).to eq(1)

  # Idempotent: a second run revokes and discards nothing.
  again = service.revoke_legacy_control!
  expect(again[:revoked]).to eq(0)
  expect(again[:discarded_jobs]).to eq(0)
end

test("revocation never copies control snapshots to execution") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)

  control_snapshot = AiConnection.create!(provider: "claude", worker_role: "control",
                                          state: "connected", checked_at: Time.current)
  legacy = legacy_control_row(provider: "claude", status: "queued")

  result = service.revoke_legacy_control!

  expect(result[:revoked]).to eq(1)
  expect(legacy.reload.status).to eq("cancelled")
  expect(AiConnection.find_by(provider: "claude", worker_role: "execution")).to eq(nil)
  expect(control_snapshot.reload.state).to eq("connected")
end

test("a stranded control job executed late still fails safe without the runtime") do |db:|
  expect(db.transaction_open?).to eq(true)
  legacy = legacy_control_row(provider: "muse", status: "queued")
  AiAuthJob.set(queue: "ai_auth_control").perform_later(legacy.uuid)
  record = SolidQueue::Job.where(class_name: "AiAuthJob", queue_name: "ai_auth_control")
    .order(id: :desc).first
  expect(record.nil?).to eq(false)
  expect(record.arguments["arguments"].first).to eq(legacy.uuid)

  runner = AiAuthTestSupport::FakeAuthRunner.immediate
  with_worker_role("execution") do
    with_test_runner(runner) do
      ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))
    end
  end

  expect(legacy.reload.status).to eq("failed")
  expect(legacy.result_error_code).to eq("role_mismatch")
  expect(runner.login_calls.size).to eq(0)
  expect(runner.status_calls.size).to eq(0)
  expect(AiConnection.find_by(provider: "muse", worker_role: "execution")).to eq(nil)
end

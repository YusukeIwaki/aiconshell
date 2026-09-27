# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

test("request emits use interaction layer with safe data only") do |db:|
  expect(db.transaction_open?).to eq(true)
  sink = WorkflowFakes::FakeEventSink.new
  service = AiAuth::RequestService.new(event_sink: sink)

  session = service.request_login(provider: "claude", worker_role: "execution")
  expect(sink.events.last[:layer]).to eq("interaction")
  expect(sink.events.last[:kind]).to eq("auth.requested")
  data = sink.events.last[:data]
  expect(data[:provider]).to eq("claude")
  expect(data.key?(:verification_uri) || data.key?("verification_uri")).to eq(false)

  session.update_columns(status: "running", claim_token: SecureRandom.uuid,
                         claimed_at: Time.current, heartbeat_at: Time.current,
                         updated_at: Time.current)
  service.cancel(session_uuid: session.uuid)
  cancel_event = sink.events.last
  expect(cancel_event[:layer]).to eq("interaction")
  expect(cancel_event[:kind]).to eq("auth.cancel_requested")
end

test("real EventLog outbox receives safe auth events") do |db:|
  expect(db.transaction_open?).to eq(true)
  before = EventDelivery.where(kind: ["auth.requested", "auth.succeeded"]).count

  with_worker_role("execution") do
    # Use the real WorkflowEvents sink (ActiveRecord outbox), not a fake.
    service = AiAuth::RequestService.new(event_sink: WorkflowEvents)
    session = service.request_login(provider: "codex", worker_role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )
    result = AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowEvents).call(session.uuid)
    expect(result.ok).to eq(true)
  end

  rows = EventDelivery.where(kind: ["auth.requested", "auth.succeeded"]).order(:id).to_a
  expect(rows.size >= before + 2).to eq(true)
  requested = rows.find { |r| r.kind == "auth.requested" }
  succeeded = rows.find { |r| r.kind == "auth.succeeded" }
  expect(requested.layer).to eq("interaction")
  expect(succeeded.layer).to eq("execution")
  [requested, succeeded].each do |row|
    envelope = row.envelope
    expect(envelope["layer"]).to eq(row.layer)
    data_json = JSON.generate(envelope["data"] || {})
    expect(data_json.include?("http")).to eq(false)
    expect(data_json.include?("verification_uri")).to eq(false)
    expect(data_json.include?("user_code")).to eq(false)
    expect(data_json.include?("encrypted")).to eq(false)
    expect(data_json.include?("SECRET")).to eq(false)
  end
end

test("execution worker result lands in execution layer outbox") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    service = AiAuth::RequestService.new(event_sink: WorkflowEvents)
    session = service.request_status(provider: "muse", worker_role: "execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "muse" => { "state" => "disconnected", "error_code" => nil } }
    )
    AiAuth::WorkerService.new(runner: runner, event_sink: WorkflowEvents).call(session.uuid)

    row = EventDelivery.where(kind: "auth.succeeded").order(id: :desc).first
    expect(row.layer).to eq("execution")
    expect(row.envelope["data"]["worker_role"]).to eq("execution")
  end
end

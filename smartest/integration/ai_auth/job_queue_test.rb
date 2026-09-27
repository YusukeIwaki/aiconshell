# frozen_string_literal: true

require "db_helper"
require_relative "ai_auth_test_support"

test("auth jobs land on the role queue and perform like a worker") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
    session = service.request_login(provider: "claude", worker_role: "control")

    record = SolidQueue::Job.find_by(class_name: "AiAuthJob", queue_name: "ai_auth_control")
    expect(record.nil?).to eq(false)
    expect(record.arguments["arguments"].first).to eq(session.uuid)

    runner = AiAuthTestSupport::FakeAuthRunner.immediate
    with_test_runner(runner) do
      ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))
    end

    expect(session.reload.status).to eq("succeeded")
    expect(AiConnection.find_by(provider: "claude", worker_role: "control").state).to eq("connected")
  end
end

test("execution role jobs use ai_auth_execution and reject the wrong worker") do |db:|
  expect(db.transaction_open?).to eq(true)
  service = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
  session = service.request_status(provider: "muse", worker_role: "execution")

  record = SolidQueue::Job.find_by(class_name: "AiAuthJob", queue_name: "ai_auth_execution")
  expect(record.nil?).to eq(false)

  runner = AiAuthTestSupport::FakeAuthRunner.new(
    status_results: { "muse" => { "state" => "connected", "error_code" => nil } }
  )
  with_worker_role("control") do
    with_test_runner(runner) do
      ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))
    end
  end

  expect(session.reload.status).to eq("failed")
  expect(session.result_error_code).to eq("role_mismatch")
  expect(runner.status_calls.size).to eq(0)
end

test("job redelivery after success is a safe duplicate") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("execution") do
    session = AiAuth::RequestService.new(event_sink: WorkflowFakes::FakeEventSink.new)
      .request_status(provider: "codex", worker_role: "execution")
    record = SolidQueue::Job.find_by(class_name: "AiAuthJob", queue_name: "ai_auth_execution")
    runner = AiAuthTestSupport::FakeAuthRunner.new(
      status_results: { "codex" => { "state" => "connected", "error_code" => nil } }
    )

    with_test_runner(runner) do
      ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))
      ActiveJob::Base.execute(record.arguments.merge("provider_job_id" => record.id))
    end

    expect(session.reload.status).to eq("succeeded")
    expect(runner.status_calls.size).to eq(1)
  end
end

test("unknown sessions are discarded without raising") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_worker_role("control") do
    with_test_runner(AiAuthTestSupport::FakeAuthRunner.immediate) do
      code = AiAuthJob.perform_now(SecureRandom.uuid)
      expect(code).to eq("unknown_session")
    end
  end
end

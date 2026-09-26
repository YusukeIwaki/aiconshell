# frozen_string_literal: true

require "db_helper"
require "securerandom"
require_relative "support/task_request_test_support"
require_relative "../../fixtures/workflow_fakes"

test("intake rejects unknown fields, blank, and overlong input without rows") do |db:|
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new
  intake = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job)
  bad_inputs = [
    { "title" => "t", "description" => "d", "source" => "x" },
    { "title" => "t", "description" => "d", "status" => "done" },
    { "title" => "   ", "description" => "blank" },
    { "title" => "t", "description" => "D" * 8001 },
    { "title" => "T" * 501, "description" => "d" },
    { "title" => 1, "description" => "d" }
  ]
  bad_inputs.each do |input|
    result = intake.call(input, idempotency_key: SecureRandom.uuid, namespace: "ui")
    expect(result.ok).to eq(false)
  end
  expect(TaskRequest.count).to eq(0)
  expect(ExternalEvent.where(plugin: "admin").count).to eq(0)
  expect(Task.count).to eq(0)
  expect(TaskRun.count).to eq(0)
  expect(sink.events.empty?).to eq(true)
  expect(job.calls.empty?).to eq(true)
end

test("intake rejects U+0000 strings without partial rows and keeps Unicode") do |db:|
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new
  intake = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job)
  nul_inputs = [
    { "title" => "bad\u0000title", "description" => "d" },
    { "title" => "t", "description" => "bad\u0000desc" },
    { "title" => "\u0000title", "description" => "d" },
    { "title" => "t", "description" => "description\u0000" },
    { "title" => "\xff".b, "description" => "d" }
  ]
  nul_inputs.each do |input|
    result = intake.call(input, idempotency_key: SecureRandom.uuid, namespace: "api")
    expect(result.ok).to eq(false)
    expect(result.code).to eq(:invalid)
  end
  expect(TaskRequest.count).to eq(0)
  expect(ExternalEvent.where(plugin: "admin").count).to eq(0)
  expect(sink.events.empty?).to eq(true)
  expect(job.calls.empty?).to eq(true)
  ok = intake.call({ "title" => "日本語\n改行", "description" => "絵文字😀\n複数行" },
    idempotency_key: SecureRandom.uuid, namespace: "api")
  expect(ok.ok).to eq(true)
  expect(TaskRequest.count).to eq(1)
end

test("intake emits a content-free event and asks triage once per receipt") do
  suffix = SecureRandom.hex(8)
  title = "emit-title-#{suffix}"
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new
  intake = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job)
  key = SecureRandom.uuid
  first = intake.call({ "title" => title, "description" => "world-#{suffix}" },
    idempotency_key: key, namespace: "ui")
  expect(first.ok).to eq(true)
  expect(first.duplicate).to eq(false)
  expect(job.calls.size).to eq(1)
  expect(sink.kinds).to eq(["task_request.accepted"])
  data = sink.events.first[:data]
  expect(data["request_id"]).to eq(first.receipt.request_id)
  expect(JSON.generate(sink.events).include?(title)).to eq(false)
  second = intake.call({ "title" => title, "description" => "world-#{suffix}" },
    idempotency_key: key, namespace: "ui")
  expect(second.ok).to eq(true)
  expect(second.receipt.request_id).to eq(first.receipt.request_id)
  expect(job.calls.size).to eq(1)
  expect(sink.events.size).to eq(1)
ensure
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("triage ask failure still accepts and stays content-free") do
  suffix = SecureRandom.hex(8)
  title = "keep-#{suffix}"
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new(error: StandardError.new("queue down"))
  intake = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job)
  result = intake.call({ "title" => title, "description" => "durable-#{suffix}" },
    idempotency_key: SecureRandom.uuid, namespace: "api")
  expect(result.ok).to eq(true)
  expect(TaskRequest.where(title: title).count).to eq(1)
  expect(sink.kinds).to eq(["task_request.accepted", "task_request.triage_ask_failed"])
  expect(JSON.generate(sink.events).include?(title)).to eq(false)
ensure
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("UI and API idempotency namespaces are independent") do |db:|
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new
  intake = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job)
  key = SecureRandom.uuid
  payload = { "title" => "same", "description" => "payload" }
  ui = intake.call(payload, idempotency_key: key, namespace: "ui")
  api = intake.call(payload, idempotency_key: key, namespace: "api")
  expect(ui.ok).to eq(true)
  expect(api.ok).to eq(true)
  expect(ui.receipt.request_id == api.receipt.request_id).to eq(false)
  expect(TaskRequest.count).to eq(2)
end

test("database enforces one receipt per namespace and key") do |db:|
  first_event = ExternalEvent.create!(plugin: "admin", event_id: "evt-race-1", fingerprint: "evt-race-1",
    event_type: "admin.task_request", resource_id: SecureRandom.uuid, actor_id: "admin",
    actor_type: "human", occurred_at: Time.current, payload: { "title" => "a" })
  second_event = ExternalEvent.create!(plugin: "admin", event_id: "evt-race-2", fingerprint: "evt-race-2",
    event_type: "admin.task_request", resource_id: SecureRandom.uuid, actor_id: "admin",
    actor_type: "human", occurred_at: Time.current, payload: { "title" => "b" })
  TaskRequest.create!(request_id: SecureRandom.uuid, idempotency_namespace: "api",
    idempotency_key: "dup-key", title: "a", description: "first", external_event: first_event)
  blocked = false
  begin
    TaskRequest.transaction(requires_new: true) do
      TaskRequest.create!(request_id: SecureRandom.uuid, idempotency_namespace: "api",
        idempotency_key: "dup-key", title: "b", description: "second", external_event: second_event)
    end
  rescue ActiveRecord::RecordNotUnique
    blocked = true
  end
  expect(blocked).to eq(true)
  expect(TaskRequest.where(idempotency_namespace: "api", idempotency_key: "dup-key").count).to eq(1)
end

test("rollback removes receipt and event and emits or enqueues nothing") do
  key = "rollback-#{SecureRandom.hex(8)}"
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new
  request_id = nil
  ActiveRecord::Base.connection_pool.with_connection do
    ActiveRecord::Base.transaction do
      result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
        { "title" => "rollback me", "description" => "will roll back" },
        idempotency_key: key, namespace: "api"
      )
      expect(result.ok).to eq(true)
      request_id = result.receipt.request_id
      expect(sink.events.empty?).to eq(true)
      expect(job.calls.empty?).to eq(true)
      expect(TaskRequest.find_by(request_id: request_id).nil?).to eq(false)
      raise ActiveRecord::Rollback
    end
  end
  ActiveRecord::Base.connection_pool.with_connection do
    expect(TaskRequest.find_by(request_id: request_id)).to eq(nil)
    expect(TaskRequest.find_by(idempotency_namespace: "api", idempotency_key: key)).to eq(nil)
    expect(ExternalEvent.where("payload->>'request_id' = ?", request_id).count).to eq(0)
  end
  expect(sink.events.empty?).to eq(true)
  expect(job.calls.empty?).to eq(true)
end

test("outer commit invokes after-accept only afterwards") do
  suffix = SecureRandom.hex(8)
  title = "commit-after-#{suffix}"
  key = "commit-after-key-#{suffix}"
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new
  request_id = nil
  ActiveRecord::Base.connection_pool.with_connection do
    ActiveRecord::Base.transaction do
      result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
        { "title" => title, "description" => "outer commit timing" },
        idempotency_key: key, namespace: "api"
      )
      expect(result.ok).to eq(true)
      request_id = result.receipt.request_id
      expect(sink.events.empty?).to eq(true)
      expect(job.calls.empty?).to eq(true)
    end
    expect(sink.kinds).to eq(["task_request.accepted"])
    expect(job.calls.size).to eq(1)
    expect(sink.events.first[:data]["request_id"]).to eq(request_id)
  end
ensure
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("queue failure cannot erase committed receipt and event") do
  suffix = SecureRandom.hex(8)
  title = "durable-queue-fail-#{suffix}"
  key = "durable-queue-fail-key-#{suffix}"
  sink = WorkflowFakes::FakeEventSink.new
  job = TaskRequestTestSupport::FakeTriageJob.new(error: StandardError.new("queue down"))
  result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
    { "title" => title, "description" => "queue fails but receipt stays" },
    idempotency_key: key, namespace: "api"
  )
  expect(result.ok).to eq(true)
  ActiveRecord::Base.connection_pool.with_connection do
    expect(TaskRequest.find_by(request_id: result.receipt.request_id).nil?).to eq(false)
    expect(ExternalEvent.where("payload->>'request_id' = ?", result.receipt.request_id).count).to eq(1)
  end
  expect(sink.kinds).to eq(["task_request.accepted", "task_request.triage_ask_failed"])
  expect(job.calls.size).to eq(1)
ensure
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("enclosing-transaction duplicate race recovers without poisoning outer transaction") do
  suffix = SecureRandom.hex(8)
  key = "race-outer-#{suffix}"
  title = "outer-title-#{suffix}"
  description = "outer-description-#{suffix}"
  winner_ready = Queue.new
  release_winner = Queue.new
  winner_outcome = Queue.new
  loser_pid = Queue.new
  winner = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      begin
        ActiveRecord::Base.transaction do
          sink = WorkflowFakes::FakeEventSink.new
          job = TaskRequestTestSupport::FakeTriageJob.new
          result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
            { "title" => title, "description" => description },
            idempotency_key: key, namespace: "api"
          )
          winner_ready << [result.ok, connection.raw_connection.backend_pid]
          TaskRequestTestSupport.pop_bounded(release_winner)
        end
        winner_outcome << :committed
      rescue StandardError => error
        begin
          winner_ready << false
        rescue StandardError
          nil
        end
        winner_outcome << error
      end
    end
  end
  accepted, winner_pid = TaskRequestTestSupport.pop_bounded(winner_ready)
  expect(accepted).to eq(true)
  loser_thread = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      loser_pid << connection.raw_connection.backend_pid
      ActiveRecord::Base.transaction do
        sink = WorkflowFakes::FakeEventSink.new
        job = TaskRequestTestSupport::FakeTriageJob.new
        result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
          { "title" => title, "description" => description },
          idempotency_key: key, namespace: "api"
        )
        later_count = TaskRequest.where(idempotency_namespace: "api", idempotency_key: key).count
        later_select = TaskRequest.connection.select_value("SELECT 1")
        [result, later_count, later_select.to_i, sink, job]
      end
    end
  end
  TaskRequestTestSupport.wait_for_blocked_session(TaskRequestTestSupport.pop_bounded(loser_pid), winner_pid)
  release_winner << true
  loser_result, later_count, later_select, loser_sink, loser_job =
    TaskRequestTestSupport.join_bounded(loser_thread)
  expect(TaskRequestTestSupport.pop_bounded(winner_outcome)).to eq(:committed)
  TaskRequestTestSupport.join_bounded(winner)
  expect(loser_result.ok).to eq(true)
  expect(loser_result.duplicate).to eq(true)
  expect(later_count).to eq(1)
  expect(later_select).to eq(1)
  expect(loser_sink.events.empty?).to eq(true)
  expect(loser_job.calls.empty?).to eq(true)
  expect(TaskRequest.where(title: title).count).to eq(1)
  expect(ExternalEvent.where("payload->>'title' = ?", title).count).to eq(1)
ensure
  begin
    release_winner << true if defined?(release_winner) && release_winner
  rescue StandardError
    nil
  end
  TaskRequestTestSupport.stop_thread(winner) if defined?(winner)
  TaskRequestTestSupport.stop_thread(loser_thread) if defined?(loser_thread)
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("enclosing-transaction conflict race returns conflict without poisoning outer transaction") do
  suffix = SecureRandom.hex(8)
  key = "race-conflict-#{suffix}"
  title = "conflict-title-#{suffix}"
  description = "conflict-description-#{suffix}"
  winner_ready = Queue.new
  release_winner = Queue.new
  winner_outcome = Queue.new
  loser_pid = Queue.new
  winner = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      begin
        ActiveRecord::Base.transaction do
          sink = WorkflowFakes::FakeEventSink.new
          job = TaskRequestTestSupport::FakeTriageJob.new
          result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
            { "title" => title, "description" => description },
            idempotency_key: key, namespace: "api"
          )
          winner_ready << [result.ok, connection.raw_connection.backend_pid]
          TaskRequestTestSupport.pop_bounded(release_winner)
        end
        winner_outcome << :committed
      rescue StandardError => error
        begin
          winner_ready << false
        rescue StandardError
          nil
        end
        winner_outcome << error
      end
    end
  end
  accepted, winner_pid = TaskRequestTestSupport.pop_bounded(winner_ready)
  expect(accepted).to eq(true)
  loser_thread = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      loser_pid << connection.raw_connection.backend_pid
      ActiveRecord::Base.transaction do
        sink = WorkflowFakes::FakeEventSink.new
        job = TaskRequestTestSupport::FakeTriageJob.new
        result = Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
          { "title" => "different-#{suffix}", "description" => "different payload" },
          idempotency_key: key, namespace: "api"
        )
        later_count = TaskRequest.where(idempotency_namespace: "api", idempotency_key: key).count
        [result, later_count, sink, job]
      end
    end
  end
  TaskRequestTestSupport.wait_for_blocked_session(TaskRequestTestSupport.pop_bounded(loser_pid), winner_pid)
  release_winner << true
  loser_result, later_count, loser_sink, loser_job =
    TaskRequestTestSupport.join_bounded(loser_thread)
  expect(TaskRequestTestSupport.pop_bounded(winner_outcome)).to eq(:committed)
  TaskRequestTestSupport.join_bounded(winner)
  expect(loser_result.ok).to eq(false)
  expect(loser_result.code).to eq(:conflict)
  expect(later_count).to eq(1)
  expect(loser_sink.events.empty?).to eq(true)
  expect(loser_job.calls.empty?).to eq(true)
  expect(TaskRequest.where(title: title).count).to eq(1)
ensure
  begin
    release_winner << true if defined?(release_winner) && release_winner
  rescue StandardError
    nil
  end
  TaskRequestTestSupport.stop_thread(winner) if defined?(winner)
  TaskRequestTestSupport.stop_thread(loser_thread) if defined?(loser_thread)
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("concurrent same-key same-payload intake persists one receipt without partials") do
  suffix = SecureRandom.hex(8)
  key = "race-same-#{suffix}"
  title = "race-title-#{suffix}"
  description = "race-description-#{suffix}"
  ready = Queue.new
  start = Queue.new
  workers = 2.times.map do
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        TaskRequestTestSupport.pop_bounded(start)
        sink = WorkflowFakes::FakeEventSink.new
        job = TaskRequestTestSupport::FakeTriageJob.new
        Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
          { "title" => title, "description" => description },
          idempotency_key: key, namespace: "api"
        )
      end
    end
  end
  2.times { TaskRequestTestSupport.pop_bounded(ready) }
  2.times { start << true }
  results = workers.map { |worker| TaskRequestTestSupport.join_bounded(worker) }
  expect(results.all?(&:ok)).to eq(true)
  expect(results.map { |result| result.receipt.request_id }.uniq.size).to eq(1)
  expect(TaskRequest.where(title: title).count).to eq(1)
  expect(ExternalEvent.where("payload->>'title' = ?", title).count).to eq(1)
ensure
  workers&.each { |worker| TaskRequestTestSupport.stop_thread(worker) }
  TaskRequestTestSupport.cleanup_receipts_by_title(title) if defined?(title) && title
end

test("concurrent distinct-key intake persists independent receipts") do
  suffix = SecureRandom.hex(8)
  ready = Queue.new
  start = Queue.new
  workers = 2.times.map do |index|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        TaskRequestTestSupport.pop_bounded(start)
        sink = WorkflowFakes::FakeEventSink.new
        job = TaskRequestTestSupport::FakeTriageJob.new
        Interaction::TaskRequestIntake.new(event_sink: sink, triage_job: job).call(
          { "title" => "distinct-#{suffix}-#{index}", "description" => "body-#{index}" },
          idempotency_key: "race-distinct-#{suffix}-#{index}", namespace: "api"
        )
      end
    end
  end
  2.times { TaskRequestTestSupport.pop_bounded(ready) }
  2.times { start << true }
  results = workers.map { |worker| TaskRequestTestSupport.join_bounded(worker) }
  expect(results.all?(&:ok)).to eq(true)
  expect(results.map { |result| result.receipt.request_id }.uniq.size).to eq(2)
  expect(TaskRequest.where("title LIKE ?", "distinct-#{suffix}-%").count).to eq(2)
ensure
  workers&.each { |worker| TaskRequestTestSupport.stop_thread(worker) }
  TaskRequestTestSupport.cleanup_receipts_like("distinct-#{suffix}-%") if defined?(suffix) && suffix
end

# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

# Persistent admin result batches (issue #11, pass 2). Real PostgreSQL, real
# plugin registry for validation only (no invoke, no network, no AI).
def admin_origin!(resource_id)
  ExternalEvent.create!(
    plugin: "admin", event_id: "evt-#{resource_id}", fingerprint: "fp-#{resource_id}",
    event_type: "admin.task_request", resource_id: resource_id,
    actor_id: "alice", actor_type: "human", occurred_at: Time.current,
    payload: { "title" => "admin request", "description" => "cross-connector check" }
  )
end

def admin_task!(resource_id, status: "ready", **attrs)
  task = Task.create!({ title: "admin request #{resource_id}", status: status,
                        source_plugin: "admin", source_resource_id: resource_id }.merge(attrs))
  admin_origin!(resource_id).update!(task: task, processed_at: Time.current)
  task
end

def result_policy!(enabled: true)
  LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: enabled)
end

def result_service(sink)
  Coordination::ResultService.new(event_sink: sink)
end

def apply_result(service, task, policy, result, feedback_ids: nil)
  ids = feedback_ids.nil? ? task.task_feedbacks.unprocessed.where(author_type: "human").order(:id).pluck(:id) : feedback_ids
  service.apply(task_id: task.id, task_version: task.lock_version,
                feedback_ids: ids, policy: policy, result: result)
end

test("admin source strings copied from another task do not grant linked-origin privilege") do |db:|
  with_workflow_env(scopes: "") do
    original = admin_task!("req-owned")
    copied = Task.create!(title: "Copied identifiers", source_plugin: original.source_plugin,
      source_resource_id: original.source_resource_id, status: "done")
    expect(original.admin_request?).to eq(true)
    expect(copied.admin_request?).to eq(false)
    result = apply_result(result_service(WorkflowFakes::FakeEventSink.new), copied, result_policy!,
      { "summary" => "Unauthorized result", "actions" => [] })
    expect(result.code).to eq(:not_admin_origin)
    expect(copied.reload.coordination_result).to eq(nil)
  end
end

test("public admin result boundary rejects blank summaries and non-coordination policies") do |db:|
  with_workflow_env(scopes: "") do
    task = admin_task!("req-boundary")
    service = result_service(WorkflowFakes::FakeEventSink.new)
    feedback = TaskFeedback.create!(task: task, body: "Pending clarification", author: "alice")
    policy = result_policy!
    expect(apply_result(service, task, policy, { "summary" => " \n\t", "actions" => [] }).code).to eq(:invalid_result)
    wrong = LayerPolicy.create!(layer: "execution", provider: "codex", enabled: true)
    expect(apply_result(service, task, wrong, { "summary" => "No work", "actions" => [] }).code).to eq(:stale_policy)
    expect(task.reload.status).to eq("ready")
    expect(task.coordination_result).to eq(nil)
    expect(feedback.reload.processed?).to eq(false)
  end
end

test("late batch persistence failure rolls back its savepoint without poisoning the caller transaction") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    task = admin_task!("req-savepoint")
    feedback = TaskFeedback.create!(task: task, body: "Keep pending on conflict", author: "alice")
    policy = result_policy!
    collision = OutboundAction.create!(plugin: "github", operation: "reply", input: {},
      idempotency_key: "result-#{task.id}-#{task.lock_version}-2")
    action = { "plugin" => "github", "operation" => "reply", "input" => { "resource_id" => "issue:owner/repo#1", "body" => "hello" } }
    Task.transaction do
      outcome = apply_result(result_service(WorkflowFakes::FakeEventSink.new), task, policy,
        { "summary" => "Atomic batch", "actions" => [action, action] })
      expect(outcome.code).to eq(:invalid_result)
      expect(task.outbound_actions.count).to eq(0)
      expect(task.reload.status).to eq("ready")
      expect(task.coordination_result).to eq(nil)
      expect(feedback.reload.processed?).to eq(false)
      expect(OutboundAction.where(id: collision.id).exists?).to eq(true)
      expect(db.select_value("SELECT 1")).to eq(1)
    end
  end
end

test("non-storable result text is classified before any PostgreSQL batch mutation") do |db:|
  with_workflow_env(scopes: "github:owner/repo,custom:scope-1") do
    custom = Class.new(Aiconshell::Plugins::Base) do
      plugin_id "custom"
      operation "reply", scope: "custom:write",
        input_schema: { "type" => "object", "required" => %w[resource_id body metadata],
          "properties" => { "resource_id" => { "type" => "string" }, "body" => { "type" => "string" },
            "metadata" => { "type" => "array", "items" => { "type" => "object" } } } },
        output_schema: Aiconshell::Plugins::Schemas::WRITE_OUTPUT
    end
    registry = Aiconshell::Plugins::Registry.new(env: {}).register(Aiconshell::Plugins::Github.new).register(custom.new)
    sink = WorkflowFakes::FakeEventSink.new
    service = Coordination::ResultService.new(registry: registry, event_sink: sink)
    task = admin_task!("req-nul")
    feedback = TaskFeedback.create!(task: task, body: "Keep pending on invalid data", author: "alice")
    policy = result_policy!
    action = { "plugin" => "github", "operation" => "reply",
      "input" => { "resource_id" => "issue:owner/repo#1", "body" => "valid" } }
    cases = [
      [{ "summary" => "bad\u0000summary", "actions" => [action] }, :invalid_result],
      [{ "summary" => "valid", "actions" => [action, action.deep_merge("input" => { "body" => "bad\u0000body" })] }, :input_invalid]
    ]
    [{ "custom" => "bad\u0000value" }, { "bad\u0000key" => "value" }].each do |metadata|
      custom_action = { "plugin" => "custom", "operation" => "reply",
        "input" => { "resource_id" => "scope-1", "body" => "valid", "metadata" => [metadata] } }
      cases << [{ "summary" => "valid", "actions" => [action, custom_action] }, :input_invalid]
    end
    cases.each do |result, expected|
      expect(apply_result(service, task, policy, result).code).to eq(expected)
      expect(task.reload.status).to eq("ready")
      expect(task.coordination_result).to eq(nil)
      expect(task.delivery_batch_key).to eq(nil)
      expect(task.outbound_actions.count).to eq(0)
      expect(feedback.reload.processed_at).to eq(nil)
      expect(db.select_value("SELECT 1")).to eq(1)
    end
    expect(sink.events.to_json.include?("bad")).to eq(false)
    # A literal escape sequence is ordinary text, not the forbidden character.
    expect(apply_result(service, task, policy, { "summary" => 'literal \\u0000', "actions" => [] }).ok).to eq(true)
  end
end

test("no-action admin result completes with summary and no runs") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = result_policy!
    task = admin_task!("req-noop")
    feedback = TaskFeedback.create!(task: task, body: "check urgent work", author: "alice", author_type: "human")
    version = task.lock_version

    outcome = apply_result(result_service(sink), task, policy,
                           { "summary" => "No high-priority issues found", "actions" => [] })

    expect(outcome.ok).to eq(true)
    expect(task.reload.status).to eq("done")
    expect(task.coordination_result).to eq({ "summary" => "No high-priority issues found", "action_count" => 0 })
    expect(task.delivery_batch_key).to eq("result-#{task.id}-#{version}")
    expect(task.next_action_at).to eq(nil)
    expect(TaskRun.where(task_id: task.id).count).to eq(0)
    expect(OutboundAction.where(task_id: task.id).count).to eq(0)
    expect(feedback.reload.processed_at.nil?).to eq(false)
    expect(sink.kinds).to eq(["result.applied"])
  end
end

test("validated batch persists atomically with stable idempotency keys") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo,discord:channel/130000000000000001") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = result_policy!
    task = admin_task!("req-batch", status: "ready")
    feedback = TaskFeedback.create!(task: task, body: "post if urgent", author: "alice", author_type: "human")
    version = task.lock_version
    jobs_before = SolidQueue::Job.where(class_name: "ExecutionRunJob").count

    outcome = apply_result(
      result_service(sink), task, policy,
      { "summary" => "Two urgent issues need cross-posting",
        "actions" => [
          { "plugin" => "github", "operation" => "reply",
            "input" => { "resource_id" => "issue:owner/repo#1", "body" => "noted" } },
          { "plugin" => "discord", "operation" => "send_message",
            "input" => { "scope" => "channel:130000000000000001", "body" => "urgent work exists" } }
        ] }
    )

    expect(outcome.ok).to eq(true)
    task.reload
    expect(task.status).to eq("waiting_delivery")
    expect(task.coordination_result).to eq({ "summary" => "Two urgent issues need cross-posting", "action_count" => 2 })
    expect(task.delivery_batch_key).to eq("result-#{task.id}-#{version}")
    actions = task.outbound_actions.order(:id).to_a
    expect(actions.map(&:idempotency_key)).to eq(
      ["result-#{task.id}-#{version}-1", "result-#{task.id}-#{version}-2"])
    expect(actions.map(&:delivery_batch_key).uniq).to eq(["result-#{task.id}-#{version}"])
    expect(actions.map(&:status).uniq).to eq(["pending"])
    expect(actions.map { |a| [a.plugin, a.operation] }).to eq(
      [["github", "reply"], ["discord", "send_message"]])
    expect(feedback.reload.processed_at.nil?).to eq(false)
    expect(TaskRun.where(task_id: task.id).count).to eq(0)
    expect(SolidQueue::Job.where(class_name: "ExecutionRunJob").count).to eq(jobs_before)
  end
end

test("invalid second action rejects with no partial mutation or feedback ack") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = result_policy!
    task = admin_task!("req-atomic")
    feedback = TaskFeedback.create!(task: task, body: "post if urgent", author: "alice", author_type: "human")
    version = task.lock_version

    outcome = apply_result(
      result_service(sink), task, policy,
      { "summary" => "Batch with a bad second action",
        "actions" => [
          { "plugin" => "github", "operation" => "reply",
            "input" => { "resource_id" => "issue:owner/repo#1", "body" => "noted" } },
          { "plugin" => "github", "operation" => "reply",
            "input" => { "resource_id" => "issue:owner/repo#2" } }
        ] }
    )

    expect(outcome.ok).to eq(false)
    expect(outcome.code).to eq(:input_invalid)
    expect(outcome.action_index).to eq(1)
    task.reload
    expect(task.status).to eq("ready")
    expect(task.lock_version).to eq(version)
    expect(task.coordination_result).to eq(nil)
    expect(task.delivery_batch_key).to eq(nil)
    expect(OutboundAction.where(task_id: task.id).count).to eq(0)
    expect(feedback.reload.processed_at).to eq(nil)
    expect(sink.kinds).to eq(["result.rejected"])
  end
end

test("disallowed destination in batch rejects without partial mutation") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = result_policy!
    task = admin_task!("req-scope")
    feedback = TaskFeedback.create!(task: task, body: "post if urgent", author: "alice", author_type: "human")

    outcome = apply_result(
      result_service(sink), task, policy,
      { "summary" => "Batch with a forbidden target",
        "actions" => [
          { "plugin" => "github", "operation" => "reply",
            "input" => { "resource_id" => "issue:owner/repo#1", "body" => "noted" } },
          { "plugin" => "github", "operation" => "reply",
            "input" => { "resource_id" => "issue:evil/repo#9", "body" => "leak" } }
        ] }
    )

    expect(outcome.ok).to eq(false)
    expect(outcome.code).to eq(:scope_not_allowed)
    expect(outcome.action_index).to eq(1)
    expect(task.reload.status).to eq("ready")
    expect(OutboundAction.where(task_id: task.id).count).to eq(0)
    expect(feedback.reload.processed_at).to eq(nil)
  end
end

test("unsupported, non-write, and unknown operations reject before mutation") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "discord:channel/130000000000000001,github:owner/repo") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = result_policy!

    unsupported = admin_task!("req-unsupported")
    outcome = apply_result(
      result_service(sink), unsupported, policy,
      { "summary" => "Discord cannot file issues",
        "actions" => [{ "plugin" => "discord", "operation" => "create_issue",
                        "input" => { "scope" => "channel:130000000000000001", "title" => "t", "body" => "b" } }] })
    expect(outcome.code).to eq(:unsupported_operation)
    expect(unsupported.reload.status).to eq("ready")

    read = admin_task!("req-readop")
    outcome = apply_result(
      result_service(sink), read, policy,
      { "summary" => "Reads are not deliverable writes",
        "actions" => [{ "plugin" => "github", "operation" => "list_issues",
                        "input" => { "scope" => "owner/repo" } }] })
    expect(outcome.code).to eq(:operation_not_allowed)
    expect(read.reload.status).to eq("ready")

    unknown = admin_task!("req-unknownop")
    outcome = apply_result(
      result_service(sink), unknown, policy,
      { "summary" => "Unknown plugin",
        "actions" => [{ "plugin" => "nope", "operation" => "reply",
                        "input" => { "resource_id" => "x", "body" => "b" } }] })
    expect(outcome.code).to eq(:unknown_plugin)
    expect(unknown.reload.status).to eq("ready")
    expect(OutboundAction.count).to eq(0)
  end
end

test("stale task version and stale policy reject results") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    service = result_service(sink)
    policy = result_policy!
    task = admin_task!("req-stale")
    TaskFeedback.create!(task: task, body: "go", author: "alice", author_type: "human")
    result = { "summary" => "No work", "actions" => [] }

    stale_version = service.apply(task_id: task.id, task_version: task.lock_version + 1,
                                  feedback_ids: [], policy: policy, result: result)
    expect(stale_version.code).to eq(:stale_task)

    snapshot = LayerPolicy.find(policy.id)
    policy.update!(enabled: false)
    disabled = apply_result(service, task, policy, result)
    expect(disabled.code).to eq(:stale_policy)

    policy.update!(enabled: true)
    changed = apply_result(service, task, snapshot, result)
    expect(changed.code).to eq(:stale_policy)

    expect(task.reload.status).to eq("ready")
    expect(task.coordination_result).to eq(nil)
    expect(TaskFeedback.unprocessed.where(task_id: task.id).count).to eq(1)
  end
end

test("duplicate application cannot create a second batch") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do
    sink = WorkflowFakes::FakeEventSink.new
    service = result_service(sink)
    policy = result_policy!
    task = admin_task!("req-dupe")
    TaskFeedback.create!(task: task, body: "go", author: "alice", author_type: "human")
    result = { "summary" => "One reply",
               "actions" => [{ "plugin" => "github", "operation" => "reply",
                               "input" => { "resource_id" => "issue:owner/repo#1", "body" => "hi" } }] }
    version = task.lock_version
    feedback_ids = task.task_feedbacks.unprocessed.order(:id).pluck(:id)

    first = service.apply(task_id: task.id, task_version: version,
                          feedback_ids: feedback_ids, policy: policy, result: result)
    expect(first.ok).to eq(true)

    second = service.apply(task_id: task.id, task_version: version,
                           feedback_ids: feedback_ids, policy: policy, result: result)
    expect(second.ok).to eq(false)
    expect(second.code).to eq(:duplicate_result)
    expect(task.outbound_actions.count).to eq(1)

    fresh = service.apply(task_id: task.id, task_version: task.reload.lock_version,
                          feedback_ids: [], policy: policy, result: result)
    expect(fresh.code).to eq(:batch_active)
    expect(task.outbound_actions.count).to eq(1)
  end
end

test("spoofed admin source strings without persisted origin are rejected") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = result_policy!
    result = { "summary" => "No work", "actions" => [] }

    spoofed = Task.create!(title: "spoofed admin", status: "ready",
                           source_plugin: "admin", source_resource_id: "req-spoofed")
    expect(spoofed.admin_request?).to eq(false)
    outcome = apply_result(result_service(sink), spoofed, policy, result)
    expect(outcome.code).to eq(:not_admin_origin)
    expect(spoofed.reload.status).to eq("ready")

    external = Task.create!(title: "ordinary issue", status: "ready",
                            source_plugin: "github", source_resource_id: "issue:owner/repo#3")
    expect(external.admin_request?).to eq(false)
    outcome = apply_result(result_service(sink), external, policy, result)
    expect(outcome.code).to eq(:not_admin_origin)

    bot_event = ExternalEvent.create!(
      plugin: "admin", event_id: "evt-bot", fingerprint: "fp-bot",
      event_type: "admin.task_request", resource_id: "req-bot",
      actor_id: "bot", actor_type: "bot", occurred_at: Time.current, payload: {})
    bot_task = Task.create!(title: "bot origin", status: "ready",
                            source_plugin: "admin", source_resource_id: "req-bot")
    expect(bot_task.admin_request?).to eq(false)
    outcome = apply_result(result_service(sink), bot_task, policy, result)
    expect(outcome.code).to eq(:not_admin_origin)

    expect(OutboundAction.count).to eq(0)
    expect(Task.where(status: "done").count).to eq(0)
  end
end

test("running tasks, current runs, and active runs reject results") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    service = result_service(sink)
    policy = result_policy!
    result = { "summary" => "No work", "actions" => [] }

    running = admin_task!("req-running", status: "running")
    run = TaskRun.create!(task: running, provider: "codex", status: "running")
    running.update!(current_run: run)
    expect(apply_result(service, running, policy, result).code).to eq(:task_running)

    pointed = admin_task!("req-pointed")
    pointer = TaskRun.create!(task: pointed, provider: "codex", status: "succeeded",
                              finished_at: Time.current)
    pointed.update!(current_run: pointer)
    expect(apply_result(service, pointed, policy, result).code).to eq(:task_running)

    active = admin_task!("req-active")
    TaskRun.create!(task: active, provider: "codex", status: "pending")
    expect(apply_result(service, active, policy, result).code).to eq(:task_running)

    legacy = admin_task!("req-legacy")
    TaskRun.create!(task: legacy, provider: "codex", status: "cancelled", finished_at: Time.current)
    expect(apply_result(service, legacy, policy, result).ok).to eq(true)
    expect(legacy.reload.status).to eq("done")
  end
end

test("new batch rejects while older actions remain outstanding") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do
    sink = WorkflowFakes::FakeEventSink.new
    service = result_service(sink)
    policy = result_policy!
    task = admin_task!("req-outstanding", status: "waiting_human")
    task.update!(coordination_result: { "summary" => "prior batch", "action_count" => 1 },
                 delivery_batch_key: "result-#{task.id}-0")
    legacy = OutboundAction.create!(
      plugin: "github", operation: "reply", task: task,
      input: { "resource_id" => "issue:owner/repo#1", "body" => "older intent" },
      idempotency_key: "legacy-pending-1", status: "pending")
    result = { "summary" => "Replacement batch",
               "actions" => [{ "plugin" => "github", "operation" => "reply",
                               "input" => { "resource_id" => "issue:owner/repo#1", "body" => "new" } }] }

    expect(apply_result(service, task, policy, result).code).to eq(:outstanding_actions)
    expect(task.reload.delivery_batch_key).to eq("result-#{task.id}-0")

    legacy.update!(status: "sending")
    expect(apply_result(service, task, policy, result).code).to eq(:outstanding_actions)

    legacy.update!(status: "sent", external_id: "ext-1")
    task.reload
    expect(apply_result(service, task, policy, result).code).to eq(:feedback_required)
    TaskFeedback.create!(task: task, body: "Please apply the revised plan", author: "alice")
    version_before = task.lock_version
    outcome = apply_result(service, task, policy, result)
    expect(outcome.ok).to eq(true)
    expect(task.reload.status).to eq("waiting_delivery")
    expect(task.delivery_batch_key).to eq("result-#{task.id}-#{version_before}")
  end
end

test("completion never replies through the admin origin") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    service = Coordination::CompletionService.new(event_sink: sink)

    admin = admin_task!("req-completion", status: "running")
    admin_run = TaskRun.create!(task: admin, provider: "codex", status: "leased",
                                lease_token: "tok-admin", lease_expires_at: 1.hour.from_now)
    admin.update!(current_run: admin_run)
    outcome = service.complete(run_id: admin_run.id, lease_token: "tok-admin",
                               result: { "outcome" => "done", "summary" => "admin work done",
                                         "reply_body" => "should never send" })
    expect(outcome.ok).to eq(true)
    expect(admin.reload.status).to eq("done")
    expect(OutboundAction.where(task_id: admin.id).count).to eq(0)

    external = Task.create!(title: "ordinary issue", status: "running",
                            source_plugin: "github", source_resource_id: "issue:owner/repo#7")
    external_run = TaskRun.create!(task: external, provider: "codex", status: "leased",
                                   lease_token: "tok-ext", lease_expires_at: 1.hour.from_now)
    external.update!(current_run: external_run)
    outcome = service.complete(run_id: external_run.id, lease_token: "tok-ext",
                               result: { "outcome" => "done", "summary" => "external work done",
                                         "reply_body" => "source reply" })
    expect(outcome.ok).to eq(true)
    expect(OutboundAction.where(task_id: external.id).count).to eq(1)
  end
end

test("one open task per source holds while waiting_delivery") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    first = Task.create!(title: "delivering", status: "waiting_delivery",
                         source_plugin: "admin", source_resource_id: "req-unique",
                         coordination_result: { "summary" => "batch", "action_count" => 1 },
                         delivery_batch_key: "result-0-0")

    raised = nil
    begin
      Task.create!(title: "dupe source", status: "ready",
                   source_plugin: "admin", source_resource_id: "req-unique")
    rescue ActiveRecord::RecordNotUnique => e
      raised = e
    end
    expect(raised.nil?).to eq(false)

    first.update!(status: "done")
    reopened = Task.create!(title: "next request", status: "inbox",
                            source_plugin: "admin", source_resource_id: "req-unique")
    expect(reopened.status).to eq("inbox")
  end
end

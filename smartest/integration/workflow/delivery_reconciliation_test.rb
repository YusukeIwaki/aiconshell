# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

# Delivery reconciliation for waiting_delivery tasks (issue #11, pass 2).
# Real PostgreSQL; no network, no AI.
def delivering_task!(resource_id, action_count:, status: "waiting_delivery")
  origin = ExternalEvent.create!(
    plugin: "admin", event_id: "evt-#{resource_id}", fingerprint: "fp-#{resource_id}",
    event_type: "admin.task_request", resource_id: resource_id,
    actor_id: "alice", actor_type: "human", occurred_at: Time.current,
    payload: { "title" => "admin request", "description" => "cross-connector check" }
  )
  task = Task.create!(title: "admin request #{resource_id}", status: status,
                      source_plugin: "admin", source_resource_id: resource_id,
                      coordination_result: { "summary" => "Batch for #{resource_id}", "action_count" => action_count },
                      delivery_batch_key: "result-batch-#{resource_id}")
  origin.update!(task: task, processed_at: Time.current)
  [task, "result-batch-#{resource_id}"]
end

def batch_action!(task, batch_key, key, status: "pending", **attrs)
  OutboundAction.create!({ plugin: "github", operation: "reply", task: task,
                           input: { "resource_id" => "issue:owner/repo##{key}", "body" => "secret-body-#{key}" },
                           idempotency_key: "batch-key-#{key}", delivery_batch_key: batch_key,
                           status: status }.merge(attrs))
end

def reconciler(sink)
  Coordination::DeliveryReconciler.new(event_sink: sink)
end

test("all-sent batch settles to done and preserves feedback") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    task, batch_key = delivering_task!("settle-done", action_count: 2)
    batch_action!(task, batch_key, "s1", status: "sent", external_id: "ext-1")
    batch_action!(task, batch_key, "s2", status: "sent", external_id: "ext-2")
    feedback = TaskFeedback.create!(task: task, body: "any update?", author: "alice", author_type: "human")

    outcome = reconciler(sink).reconcile(task_id: task.id)

    expect(outcome.ok).to eq(true)
    expect(outcome.code).to eq(:settled_done)
    task.reload
    expect(task.status).to eq("done")
    expect(task.next_action_at).to eq(nil)
    expect(task.last_error).to eq(nil)
    expect(task.delivery_batch_key).to eq(batch_key)
    expect(task.coordination_result).to eq({ "summary" => "Batch for settle-done", "action_count" => 2 })
    expect(feedback.reload.processed_at).to eq(nil)
    expect(sink.events.last[:data]).to eq({ action_count: 2, outcome: "done" })
  end
end

test("failed batch parks as waiting_human with a content-free reason") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    task, batch_key = delivering_task!("settle-failed", action_count: 2)
    batch_action!(task, batch_key, "f1", status: "sent", external_id: "ext-1")
    batch_action!(task, batch_key, "f2", status: "failed",
                  error_code: "scope_not_allowed", error: "Outbound delivery: scope_not_allowed")
    feedback = TaskFeedback.create!(task: task, body: "retry please", author: "alice", author_type: "human")

    outcome = reconciler(sink).reconcile(task_id: task.id)

    expect(outcome.ok).to eq(true)
    expect(outcome.code).to eq(:settled_waiting_human)
    task.reload
    expect(task.status).to eq("waiting_human")
    expect(task.next_action_at).to eq(nil)
    expect(task.last_error).to eq("Delivery requires operator review (delivery_failed)")
    expect(task.last_error.include?("secret-body")).to eq(false)
    expect(task.delivery_batch_key).to eq(batch_key)
    expect(feedback.reload.processed_at).to eq(nil)
    expect(OutboundAction.where(task_id: task.id, status: %w[pending sending]).count).to eq(0)
    expect(sink.events.last[:data][:error_code]).to eq("delivery_failed")
  end
end

test("uncertain batch parks as waiting_human without autonomous resend") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    task, batch_key = delivering_task!("settle-uncertain", action_count: 1)
    action = batch_action!(task, batch_key, "u1", status: "uncertain",
                           error_code: "delivery_uncertain", error: "Delivery outcome requires operator review")

    outcome = reconciler(sink).reconcile(task_id: task.id)

    expect(outcome.code).to eq(:settled_waiting_human)
    expect(task.reload.status).to eq("waiting_human")
    expect(task.last_error).to eq("Delivery requires operator review (delivery_uncertain)")
    expect(task.next_action_at).to eq(nil)
    expect(action.reload.status).to eq("uncertain")
    expect(action.next_attempt_at).to eq(nil)
  end
end

test("mixed terminal plus pending actions stay waiting_delivery") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    task, batch_key = delivering_task!("settle-mixed", action_count: 3)
    batch_action!(task, batch_key, "m1", status: "sent", external_id: "ext-1")
    batch_action!(task, batch_key, "m2", status: "failed", error_code: "delivery_rejected")
    batch_action!(task, batch_key, "m3", status: "pending")

    outcome = reconciler(sink).reconcile(task_id: task.id)

    expect(outcome.ok).to eq(false)
    expect(outcome.code).to eq(:batch_pending)
    expect(task.reload.status).to eq("waiting_delivery")
    expect(task.last_error).to eq(nil)
  end
end

test("sending actions keep the batch waiting_delivery") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new
    task, batch_key = delivering_task!("settle-sending", action_count: 1)
    batch_action!(task, batch_key, "g1", status: "sending", lease_token: "lease-1",
                  lease_expires_at: 5.minutes.from_now)

    expect(reconciler(sink).reconcile(task_id: task.id).code).to eq(:batch_pending)
    expect(task.reload.status).to eq("waiting_delivery")
  end
end

test("missing or mismatched action counts never vacuously succeed") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    sink = WorkflowFakes::FakeEventSink.new

    deleted, deleted_key = delivering_task!("settle-deleted", action_count: 2)
    batch_action!(deleted, deleted_key, "d1", status: "sent", external_id: "ext-1")
    batch_action!(deleted, deleted_key, "d2", status: "sent", external_id: "ext-2")
    OutboundAction.find_by(idempotency_key: "batch-key-d2").destroy!
    outcome = reconciler(sink).reconcile(task_id: deleted.id)
    expect(outcome.code).to eq(:batch_mismatch)
    expect(deleted.reload.status).to eq("waiting_human")
    expect(deleted.last_error).to eq("Delivery batch incomplete (batch_mismatch)")
    expect(deleted.delivery_batch_key).to eq(deleted_key)

    extra, extra_key = delivering_task!("settle-extra", action_count: 1)
    batch_action!(extra, extra_key, "e1", status: "sent", external_id: "ext-1")
    batch_action!(extra, extra_key, "e2", status: "sent", external_id: "ext-2")
    expect(reconciler(sink).reconcile(task_id: extra.id).code).to eq(:batch_mismatch)
    expect(extra.reload.status).to eq("waiting_human")

    lost, _lost_key = delivering_task!("settle-lost", action_count: 0)
    lost.update!(coordination_result: { "summary" => "corrupt", "action_count" => 0 },
                 delivery_batch_key: nil)
    expect(reconciler(sink).reconcile(task_id: lost.id).code).to eq(:batch_mismatch)
    expect(lost.reload.status).to eq("waiting_human")
  end
end

test("mismatch recovery still blocks replanning while old actions are outstanding") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do
    sink = WorkflowFakes::FakeEventSink.new
    policy = LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    task, batch_key = delivering_task!("settle-replan", action_count: 2)
    batch_action!(task, batch_key, "r1", status: "sent", external_id: "ext-1")
    pending = batch_action!(task, batch_key, "r2", status: "pending")
    OutboundAction.find_by(idempotency_key: "batch-key-r1").destroy!
    TaskFeedback.create!(task: task, body: "what happened?", author: "alice", author_type: "human")

    expect(reconciler(sink).reconcile(task_id: task.id).code).to eq(:batch_mismatch)
    expect(task.reload.status).to eq("waiting_human")

    fresh = { "summary" => "Replacement batch",
              "actions" => [{ "plugin" => "github", "operation" => "reply",
                              "input" => { "resource_id" => "issue:owner/repo#1", "body" => "retry" } }] }
    service = Coordination::ResultService.new(event_sink: sink)
    blocked = service.apply(task_id: task.id, task_version: task.lock_version,
                            feedback_ids: task.task_feedbacks.unprocessed.order(:id).pluck(:id),
                            policy: policy, result: fresh)
    expect(blocked.code).to eq(:outstanding_actions)

    pending.update!(status: "failed", error_code: "delivery_rejected")
    TaskFeedback.create!(task: task, body: "please retry once", author: "alice", author_type: "human")
    task.reload
    retrying = service.apply(task_id: task.id, task_version: task.lock_version,
                             feedback_ids: task.task_feedbacks.unprocessed.order(:id).pluck(:id),
                             policy: policy, result: fresh)
    expect(retrying.ok).to eq(true)
    expect(task.reload.status).to eq("waiting_delivery")
    expect(task.delivery_batch_key == batch_key).to eq(false)
    expect(task.coordination_result).to eq({ "summary" => "Replacement batch", "action_count" => 1 })
    expect(TaskFeedback.unprocessed.where(task_id: task.id).count).to eq(0)
  end
end

test("maintenance reconciles delivery while execution is disabled") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    expect(LayerPolicy.enabled_for("execution")).to eq(nil)
    task, batch_key = delivering_task!("settle-maintenance", action_count: 1)
    batch_action!(task, batch_key, "mt1", status: "sent", external_id: "ext-1")
    jobs_before = SolidQueue::Job.where(class_name: "ExecutionRunJob").count

    WorkflowMaintenanceJob.perform_now

    expect(task.reload.status).to eq("done")
    expect(SolidQueue::Job.where(class_name: "ExecutionRunJob").count).to eq(jobs_before)
  end
end

test("work context exposes bounded prior result and delivery metadata without bodies") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    task = Task.create!(title: "prior attempts", status: "waiting_human",
                        source_plugin: "admin", source_resource_id: "req-context",
                        coordination_result: { "summary" => "x" * 2000, "action_count" => 2 },
                        delivery_batch_key: "result-ctx-1")
    OutboundAction.create!(
      plugin: "github", operation: "reply", task: task,
      input: { "resource_id" => "issue:owner/repo#1", "body" => "secret-body-ctx" },
      idempotency_key: "ctx-1", delivery_batch_key: "result-ctx-1",
      status: "failed", error_code: "delivery_rejected", error: "Outbound delivery: delivery_rejected")
    OutboundAction.create!(
      plugin: "teams", operation: "send_message", task: task,
      input: { "scope" => "team/t1/channel/c1", "body" => "secret-body-ctx" },
      idempotency_key: "ctx-2", delivery_batch_key: "result-ctx-1",
      status: "sent", external_id: "ext-9")

    context = Coordination::WorkContext.for_task(task)

    expect(context["coordination_result"]).to eq({ "summary" => "x" * 500, "summary_truncated" => true, "action_count" => 2 })
    expect(context["deliveries"]).to eq([
      { "batch_key" => "result-ctx-1", "plugin" => "github", "operation" => "reply",
        "destination" => "owner/repo", "status" => "failed", "error_code" => "delivery_rejected" },
      { "batch_key" => "result-ctx-1", "plugin" => "teams", "operation" => "send_message",
        "destination" => "team/t1/channel/c1", "status" => "sent", "error_code" => nil }
    ])
    expect(JSON.generate(context).include?("secret-body-ctx")).to eq(false)

    fresh = Task.create!(title: "no prior batch", status: "inbox")
    fresh_context = Coordination::WorkContext.for_task(fresh)
    expect(fresh_context["coordination_result"]).to eq(nil)
    expect(fresh_context["deliveries"]).to eq([])
  end
end

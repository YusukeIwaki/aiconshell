# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

def maintenance_run(task_status: "running", run_status: "pending", current: true)
  task = Task.create!(title: "Persisted request awaiting queue repair", description: "No AI is executed by this test",
                      status: task_status, priority: 10)
  run = TaskRun.create!(task: task, provider: "codex", status: run_status,
                        work_snapshot: Coordination::WorkContext.for_task(task))
  task.update!(current_run: run) if current
  run
end

def maintenance_new_jobs(class_name, prior_ids)
  SolidQueue::Job.where(class_name: class_name).where.not(id: prior_ids).order(:id).to_a
end

test("maintenance repairs lost enqueue only for an enabled current pending execution") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    prior_ids = SolidQueue::Job.where(class_name: "ExecutionRunJob").pluck(:id)
    # Persist requests directly, reproducing a crash between DB persistence
    # and enqueue. No execution job has been created for any of these rows.
    expected = maintenance_run
    no_pointer = maintenance_run(current: false)
    cancelled_task = maintenance_run(task_status: "cancelled")
    terminal_run = maintenance_run(run_status: "succeeded")
    expect(maintenance_new_jobs("ExecutionRunJob", prior_ids)).to eq([])

    WorkflowMaintenanceJob.perform_now
    expect(maintenance_new_jobs("ExecutionRunJob", prior_ids)).to eq([])

    policy = LayerPolicy.create!(layer: "execution", provider: "codex", enabled: false)
    WorkflowMaintenanceJob.perform_now
    expect(maintenance_new_jobs("ExecutionRunJob", prior_ids)).to eq([])

    policy.update!(enabled: true)
    WorkflowMaintenanceJob.perform_now
    jobs = maintenance_new_jobs("ExecutionRunJob", prior_ids)
    expect(jobs.map { |job| job.arguments.fetch("arguments") }).to eq([[expected.id]])
    expect(jobs.first.queue_name).to eq("execution")
    expect(jobs.first.ready_execution.nil?).to eq(false)
    expect(expected.reload.status).to eq("pending")
    expect(no_pointer.reload.status).to eq("pending")
    expect(cancelled_task.reload.status).to eq("pending")
    expect(terminal_run.reload.status).to eq("succeeded")
  end
end

test("maintenance enqueues due outbound intents but preserves future backoff and uncertain sends") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "") do
    prior_ids = SolidQueue::Job.where(class_name: "OutboundDeliveryJob").pluck(:id)
    make_action = lambda do |key, **attributes|
      OutboundAction.create!({ plugin: "github", operation: "reply",
                               input: { "resource_id" => "issue:owner/repo#1", "body" => "Persisted intent" },
                               idempotency_key: "maintenance-#{key}", status: "pending" }.merge(attributes))
    end
    fresh = make_action.call("fresh")
    due = make_action.call("due", next_attempt_at: 1.minute.ago)
    delayed = make_action.call("delayed", next_attempt_at: 1.hour.from_now)
    uncertain = make_action.call("uncertain", status: "uncertain")
    delayed_until = delayed.next_attempt_at

    WorkflowMaintenanceJob.perform_now

    jobs = maintenance_new_jobs("OutboundDeliveryJob", prior_ids)
    expect(jobs.map { |job| job.arguments.fetch("arguments").first }.sort).to eq([fresh.id, due.id].sort)
    expect(jobs.all? { |job| job.queue_name == "control" && job.ready_execution.present? }).to eq(true)
    expect(delayed.reload.next_attempt_at).to eq(delayed_until)
    expect(delayed.status).to eq("pending")
    expect(uncertain.reload.status).to eq("uncertain")
    expect([fresh, due, delayed, uncertain].all? { |action| action.reload.attempts.zero? }).to eq(true)
    expect([fresh, due, delayed, uncertain].all? { |action| action.external_id.nil? }).to eq(true)
  end
end

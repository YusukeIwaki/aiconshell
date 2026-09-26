# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

def seed_running_task(status: "running")
  Task.create!(title: "t", description: "do work", status: status, priority: 1,
               source_plugin: "github", source_resource_id: "issue-1")
end

test("duplicate execution jobs are rejected without stealing the lease") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = seed_running_task
    run = TaskRun.create!(task: task, provider: "codex", status: "pending")
    ai = WorkflowFakes::FakeAiRunner.new(
      answers: { "execution" => { "outcome" => "done", "summary" => "ok" } }
    )
    runner = Execution::RunnerService.new(ai_runner: ai, event_sink: sink)

    first = runner.call(run.id)
    lease_after_first = run.reload.lease_token
    second = runner.call(run.id)

    expect(first.ok).to eq(true)
    expect(second.ok).to eq(false)
    expect(second.code).to eq(:duplicate_job)
    expect(run.reload.lease_token).to eq(lease_after_first)
    expect(ai.calls.size).to eq(1)
  end
end

test("unconfigured execution provider produces a structured failure") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = seed_running_task
    run = TaskRun.create!(task: task, provider: "muse", status: "pending")
    ai = WorkflowFakes::FakeAiRunner.new(
      errors: { "execution" => WorkflowFakes::FakeNotConfigured.new("subscription login missing") }
    )

    result = Execution::RunnerService.new(ai_runner: ai, event_sink: sink).call(run.id)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:provider_not_configured)
    expect(run.reload.status).to eq("failed")
    expect(run.error_code).to eq("provider_not_configured")
    expect(task.reload.status).to eq("failed")
    expect(task.last_error.nil?).to eq(false)
    expect(sink.kinds.include?("run.failed")).to eq(true)
  end
end

test("stale completions with a wrong lease token are fenced out") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = seed_running_task
    run = TaskRun.create!(task: task, provider: "codex", status: "running",
                          lease_token: "live-token", lease_expires_at: 10.minutes.from_now)
    completion = Coordination::CompletionService.new(event_sink: sink)

    stale = completion.complete(run_id: run.id, lease_token: "old-token",
                                result: { "outcome" => "done", "summary" => "stale" })
    expect(stale.ok).to eq(false)
    expect(stale.code).to eq(:stale_completion)
    expect(task.reload.status).to eq("running")

    fresh = completion.complete(run_id: run.id, lease_token: "live-token",
                                result: { "outcome" => "done", "summary" => "fresh" })
    expect(fresh.ok).to eq(true)
    expect(task.reload.status).to eq("done")

    replay = completion.complete(run_id: run.id, lease_token: "live-token",
                                 result: { "outcome" => "failed", "summary" => "replay" })
    expect(replay.ok).to eq(false)
    expect(task.reload.status).to eq("done")
  end
end

test("expired leases recover into a fresh run, then park the task when exhausted") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = seed_running_task
    run = TaskRun.create!(task: task, provider: "codex", status: "running", attempt: 1,
                          lease_token: "expired-token", lease_expires_at: 1.minute.ago)
    recovery = Coordination::RecoveryService.new(event_sink: sink)

    expect(recovery.call).to eq(1)
    expect(run.reload.status).to eq("expired")
    fresh = TaskRun.where(task: task, status: "pending").last
    expect(fresh.nil?).to eq(false)
    expect(fresh.attempt).to eq(2)
    # The expired token can never complete, even with a valid outcome.
    stale = Coordination::CompletionService.new(event_sink: sink).complete(
      run_id: run.id, lease_token: "expired-token",
      result: { "outcome" => "done", "summary" => "late" }
    )
    expect(stale.ok).to eq(false)

    fresh.update!(status: "running", lease_token: "expired-2", lease_expires_at: 1.minute.ago,
                  attempt: WorkflowSettings.max_run_attempts)
    expect(recovery.call).to eq(1)
    expect(task.reload.status).to eq("failed")
    expect(task.last_error.include?("exhausted")).to eq(true)
  end
end

test("heartbeat extends a live lease but never a terminal run") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = seed_running_task
    run = TaskRun.create!(task: task, provider: "codex", status: "running",
                          lease_token: "token", lease_expires_at: 1.minute.from_now)
    runner = Execution::RunnerService.new(ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: sink)

    expect(runner.heartbeat(run.id, "token")).to eq(true)
    expect(run.reload.lease_expires_at > 1.hour.from_now).to eq(false)
    expect(run.lease_expires_at > 10.minutes.from_now).to eq(true)
    expect(runner.heartbeat(run.id, "wrong-token")).to eq(false)

    run.update!(status: "succeeded")
    expect(runner.heartbeat(run.id, "token")).to eq(false)
  end
end

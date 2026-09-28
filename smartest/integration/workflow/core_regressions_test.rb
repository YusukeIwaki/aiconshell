# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

# A block runner provides deterministic interleavings at the AI boundary.
# It never starts a subprocess or uses a provider account.
class CoreBlockRunner
  attr_reader :calls
  def initialize(&block)
    @block = block
    @calls = []
  end

  def call(**input)
    @calls << input
    @block.call(input)
  end
end

def core_policy(layer = "execution", enabled: true)
  LayerPolicy.create!(layer: layer, provider: "codex", enabled: enabled)
end

def core_task(**attributes)
  Task.create!({ title: "repair login", description: "Original problem details", status: "ready" }.merge(attributes))
end

def core_dispatch(task, clock: Time)
  Coordination::DispatchService.new(event_sink: WorkflowFakes::FakeEventSink.new, clock: clock).dispatch(task)
end

def core_feedback(task, body)
  TaskFeedback.create!(task: task, body: body, author: "reviewer", author_type: "human")
end

def core_event(id, resource:, actor: "human", payload: { "body" => "update" })
  ExternalEvent.create!(plugin: "github", event_id: id, fingerprint: id, event_type: "github.issue_comment",
                        resource_id: resource, actor_id: "reviewer", actor_type: actor,
                        occurred_at: Time.current, payload: payload)
end

test("dispatch is idempotent and PostgreSQL enforces one active run") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    task = core_task
    first = core_dispatch(task)
    second = core_dispatch(Task.find(task.id))
    expect(second.id).to eq(first.id)
    expect(task.task_runs.active.count).to eq(1)
    expect(task.reload.current_run_id).to eq(first.id)
    blocked = false
    begin
      TaskRun.transaction(requires_new: true) do
        TaskRun.create!(task: task, provider: "codex", status: "pending")
      end
    rescue ActiveRecord::RecordNotUnique
      blocked = true
    end
    expect(blocked).to eq(true)
  end
end

test("disabled execution policy blocks dispatch and defers already queued work") do |db:|
  with_workflow_env(scopes: "") do
    task = core_task
    expect(core_dispatch(task)).to eq(nil)
    policy = core_policy(enabled: false)
    expect(core_dispatch(task)).to eq(nil)
    policy.update!(enabled: true)
    run = core_dispatch(task)
    policy.update!(enabled: false)
    ai = CoreBlockRunner.new { raise "must never call AI" }
    result = Execution::RunnerService.new(ai_runner: ai).call(run.id)
    expect(result.code).to eq(:execution_disabled)
    expect(run.reload.status).to eq("pending")
    expect(ai.calls.empty?).to eq(true)
  end
end

test("exact feedback snapshot excludes new arrivals and rejected or omitted tasks") do |db:|
  with_workflow_env(scopes: "") do
    core_policy("coordination")
    accepted = core_task(status: "inbox")
    rejected = core_task(status: "inbox")
    omitted = core_task(status: "inbox")
    old = 6.times.map { |i| core_feedback(accepted, "clarification #{i}") }
    bad = core_feedback(rejected, "rejecting this ruling must retain my answer")
    untouched = core_feedback(omitted, "omitted task answer")
    incoming = nil
    ai = CoreBlockRunner.new do |input|
      expect(input[:prompt].include?("clarification 5")).to eq(true)
      incoming = core_feedback(accepted, "arrived while AI was running")
      { "rulings" => [
        { "task_id" => accepted.id, "status" => "ready" },
        { "task_id" => rejected.id, "status" => "done" }
      ] }
    end
    result = Coordination::TriageService.new(ai_runner: ai).call
    expect(result.triaged).to eq(1)
    expect(result.rejected).to eq(1)
    expect(old.all? { |f| f.reload.processed? }).to eq(true)
    expect([incoming, bad, untouched].any? { |f| f.reload.processed? }).to eq(false)
  end
end

test("stale triage decision cannot overwrite completion or acknowledge feedback") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    core_policy("coordination")
    task = core_task
    run = core_dispatch(task)
    run.update!(status: "running", lease_token: "live", lease_expires_at: 1.hour.from_now)
    feedback = core_feedback(task, "review after completion")
    ai = CoreBlockRunner.new do
      completed = Coordination::CompletionService.new.complete(
        run_id: run.id, lease_token: "live", result: { "outcome" => "waiting_review", "summary" => "finished" }
      )
      expect(completed.ok).to eq(true)
      { "rulings" => [{ "task_id" => task.id, "status" => "failed" }] }
    end
    result = Coordination::TriageService.new(ai_runner: ai).call
    expect(result.rejected).to eq(1)
    expect(task.reload.status).to eq("waiting_review")
    expect(feedback.reload.processed?).to eq(false)
  end
end

test("coordination cancellation prevents queued execution and expired recovery") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    core_policy("coordination")
    task = core_task
    run = core_dispatch(task)
    core_feedback(task, "please cancel")
    triage_ai = CoreBlockRunner.new { { "rulings" => [{ "task_id" => task.id, "status" => "cancelled" }] } }
    Coordination::TriageService.new(ai_runner: triage_ai).call
    worker_ai = CoreBlockRunner.new { raise "cancelled task reached AI" }
    result = Execution::RunnerService.new(ai_runner: worker_ai).call(run.id)
    expect(result.ok).to eq(false)
    expect(run.reload.status).to eq("cancelled")
    expect(task.reload.current_run_id).to eq(nil)
    expect(Coordination::RecoveryService.new.call).to eq(0)
    expect(worker_ai.calls.empty?).to eq(true)
    expect(task.task_runs.count).to eq(1)
  end
end

test("worker result and heartbeat cannot revive an expired lease") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    task = core_task
    run = core_dispatch(task)
    run.update!(status: "running", lease_token: "expired", lease_expires_at: 1.second.ago)
    completion = Coordination::CompletionService.new
    result = completion.complete(run_id: run.id, lease_token: "expired", result: { "outcome" => "done", "summary" => "late" })
    expect(result.code).to eq(:stale_completion)
    expect(Execution::RunnerService.new(ai_runner: Object.new).heartbeat(run.id, "expired")).to eq(false)
    expect(task.reload.status).to eq("running")
  end
end

test("task pointer fences an old lease even when its token is valid") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    task = core_task
    old = core_dispatch(task)
    old.update!(status: "running", lease_token: "old", lease_expires_at: 1.hour.from_now)
    task.update!(current_run_id: nil, status: "cancelled")
    result = Coordination::CompletionService.new.fail_run(run_id: old.id, lease_token: "old", error_code: "late", error: "late failure")
    expect(result.code).to eq(:stale_completion)
    expect(task.reload.status).to eq("cancelled")
    expect(task.last_error).to eq(nil)
    old.update!(lease_expires_at: 1.second.ago)
    expect(Coordination::RecoveryService.new.call).to eq(1)
    expect(old.reload.status).to eq("cancelled")
    expect(task.task_runs.count).to eq(1)
  end
end

test("clarification and prior result are carried into immutable dispatch input") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    core_policy("coordination")
    task = core_task(status: "waiting_human", work_plan: "Earlier plan")
    TaskRun.create!(task: task, provider: "codex", status: "succeeded",
                    result: { "outcome" => "waiting_human", "summary" => "Which environment?" })
    core_feedback(task, "Use the staging environment")
    ai = CoreBlockRunner.new do |input|
      if input[:layer] == "coordination"
        %w[description prior_result work_plan].each { |key| expect(input[:prompt].include?(key)).to eq(true) }
        expect(input[:prompt].include?("Which environment?")).to eq(true)
        { "rulings" => [{ "task_id" => task.id, "status" => "ready", "dispatch" => true,
                          "work_plan" => "Apply the repair on staging" }] }
      else
        expect(input[:prompt].include?("Use the staging environment")).to eq(true)
        expect(input[:prompt].include?("Apply the repair on staging")).to eq(true)
        expect(input[:prompt].include?("Which environment?")).to eq(true)
        expect(input[:prompt].include?("Changed after dispatch")).to eq(false)
        { "outcome" => "done", "summary" => "Done" }
      end
    end
    expect(Coordination::TriageService.new(ai_runner: ai).call.triaged).to eq(1)
    run = task.reload.current_run
    task.update!(description: "Changed after dispatch")
    expect(Execution::RunnerService.new(ai_runner: ai).call(run.id).ok).to eq(true)
  end
end

test("unknown outcome is a structured failed run rather than silent success") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    task = core_task
    run = core_dispatch(task)
    ai = CoreBlockRunner.new { { "outcome" => "anything", "summary" => "not an accepted outcome" } }
    result = Execution::RunnerService.new(ai_runner: ai).call(run.id)
    expect(result.code).to eq(:provider_invalid_output)
    expect(result.ok).to eq(false)
    expect(run.reload.status).to eq("failed")
    expect(task.reload.status).to eq("failed")
  end
end

test("lease bounds fail before dispatch and symlinked workspaces fail before AI") do |db:|
  with_workflow_env(scopes: "", lease_seconds: 60, ai_timeout_seconds: 600) do
    core_policy
    task = core_task
    error = nil
    begin
      core_dispatch(task)
    rescue ArgumentError => caught
      error = caught
    end
    expect(error.nil?).to eq(false)
    expect(task.task_runs.count).to eq(0)
  end
  with_workflow_env(scopes: "") do |root|
    task = core_task
    run = core_dispatch(task)
    Dir.mktmpdir("aiconshell-outside-") do |outside|
      File.symlink(outside, File.join(root, "task_#{task.id}"))
      ai = CoreBlockRunner.new { raise "must not reach AI" }
      result = Execution::RunnerService.new(ai_runner: ai).call(run.id)
      expect(result.code).to eq(:workspace_rejected)
      expect(Dir.children(outside)).to eq([])
      expect(ai.calls.empty?).to eq(true)
    end
  end
end

test("bodyless source changes and system context remain useful without bot feedback") do |db:|
  with_workflow_env(scopes: "") do
    original = core_event("one", resource: "issue:CORE-1")
    change = core_event("two", resource: "issue:CORE-1", payload: { "items" => ["status:Open->Review"] })
    system = core_event("three", resource: "issue:CORE-1", actor: "system", payload: { "state" => "closed" })
    expect(Coordination::TriageService.new(ai_runner: Object.new).call.ingested).to eq(3)
    task = original.reload.task
    expect(change.reload.task_id).to eq(task.id)
    expect(system.reload.task_id).to eq(task.id)
    expect(task.task_feedbacks.count).to eq(1)
    expect(task.task_feedbacks.first.body).to eq("status:Open->Review")
    expect(Coordination::WorkContext.for_task(task)["events"].last["payload"]).to eq({ "state" => "closed" })
  end
end

test("malformed inbox row is quarantined without blocking later sources") do |db:|
  with_workflow_env(scopes: "") do
    bad = core_event("invalid", resource: "issue:CORE-2", payload: [])
    good = core_event("valid", resource: "issue:CORE-3")
    result = Coordination::TriageService.new(ai_runner: Object.new).call
    expect(result.ingested).to eq(1)
    expect(bad.reload.last_error.start_with?("ingest_rejected:")).to eq(true)
    expect(good.reload.task.nil?).to eq(false)
  end
end

test("completed source receives a new open task and PostgreSQL prevents duplicate open sources") do |db:|
  with_workflow_env(scopes: "") do
    closed = core_task(status: "done", source_plugin: "github", source_resource_id: "issue:CORE-4")
    event = core_event("new", resource: "issue:CORE-4")
    Coordination::TriageService.new(ai_runner: Object.new).call
    expect(event.reload.task_id == closed.id).to eq(false)
    expect(event.task.status).to eq("inbox")
    blocked = false
    begin
      Task.transaction(requires_new: true) do
        core_task(source_plugin: "github", source_resource_id: "issue:CORE-4")
      end
    rescue ActiveRecord::RecordNotUnique
      blocked = true
    end
    expect(blocked).to eq(true)
  end
end

test("simultaneous PostgreSQL dispatches share one persisted execution request") do
  # Committed rows are deliberate: separate PostgreSQL connections must see
  # the same task. Everything created by this test is removed in ensure.
  with_workflow_env(scopes: "") do
    policy = core_policy
    task = core_task
    original_job_ids = SolidQueue::Job.where(class_name: "ExecutionRunJob").pluck(:id)
    ready = Queue.new
    start = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          core_dispatch(Task.find(task.id)).id
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    ids = workers.map(&:value)
    expect(ids.uniq.size).to eq(1)
    expect(task.task_runs.active.count).to eq(1)
    expect(task.reload.current_run_id).to eq(ids.first)
  ensure
    workers&.each(&:join)
    task&.destroy!
    policy&.destroy!
    SolidQueue::Job.where(class_name: "ExecutionRunJob").where.not(id: original_job_ids || []).destroy_all
  end
end

test("worker reports stale completion when coordination cancels during AI") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    core_policy("coordination")
    task = core_task
    run = core_dispatch(task)
    ai = CoreBlockRunner.new do
      core_feedback(task, "cancel this work")
      cancel = CoreBlockRunner.new { { "rulings" => [{ "task_id" => task.id, "status" => "cancelled" }] } }
      expect(Coordination::TriageService.new(ai_runner: cancel).call.triaged).to eq(1)
      { "outcome" => "done", "summary" => "too late" }
    end
    result = Execution::RunnerService.new(ai_runner: ai).call(run.id)
    expect(result.ok).to eq(false)
    expect(result.code).to eq(:stale_completion)
    expect(task.reload.status).to eq("cancelled")
    expect(run.reload.status).to eq("cancelled")
  end
end

test("duplicate AI rulings cannot dispatch twice and arbitrary reply destinations are rejected") do |db:|
  with_workflow_env(scopes: "github:owner/repo") do
    core_policy
    core_policy("coordination")
    task = core_task(status: "inbox", source_plugin: "github", source_resource_id: "issue:owner/repo#10")
    feedback = core_feedback(task, "keep it in this issue")
    wrong = CoreBlockRunner.new do
      { "rulings" => [{ "task_id" => task.id, "reply" => { "body" => "hello", "resource_id" => "issue:other/repo#1" } }] }
    end
    expect(Coordination::TriageService.new(ai_runner: wrong).call.rejected).to eq(1)
    expect(feedback.reload.processed?).to eq(false)
    expect(OutboundAction.count).to eq(0)
    good = CoreBlockRunner.new do
      { "rulings" => 2.times.map { { "task_id" => task.id, "status" => "ready", "dispatch" => true } } }
    end
    result = Coordination::TriageService.new(ai_runner: good).call
    expect(result.triaged).to eq(1)
    expect(result.rejected).to eq(1)
    expect(task.task_runs.count).to eq(1)
  end
end

test("feedback arriving during completion remains triageable and can reopen explicitly") do |db:|
  with_workflow_env(scopes: "") do
    core_policy
    core_policy("coordination")
    task = core_task
    run = core_dispatch(task)
    incoming = nil
    execute = CoreBlockRunner.new do
      incoming = core_feedback(task, "One more requirement arrived during the run")
      { "outcome" => "done", "summary" => "original work complete" }
    end
    expect(Execution::RunnerService.new(ai_runner: execute).call(run.id).ok).to eq(true)
    expect(task.reload.status).to eq("done")
    expect(incoming.reload.processed?).to eq(false)
    triage = CoreBlockRunner.new do |input|
      expect(input[:prompt].include?("One more requirement")).to eq(true)
      { "rulings" => [{ "task_id" => task.id, "status" => "inbox", "work_plan" => "Handle the new requirement" }] }
    end
    expect(Coordination::TriageService.new(ai_runner: triage).call.triaged).to eq(1)
    expect(task.reload.status).to eq("inbox")
    expect(task.current_run_id).to eq(nil)
    expect(incoming.reload.processed?).to eq(true)
    expect(run.reload.status).to eq("succeeded")
  end
end

test("late external event ownership prevents reopening an older completed source") do |db:|
  with_workflow_env(scopes: "") do
    core_policy("coordination")
    old = core_task(status: "done", source_plugin: "github", source_resource_id: "issue:CORE-LATE")
    feedback = core_feedback(old, "continue this discussion")
    event = nil
    ai = CoreBlockRunner.new do
      event = core_event("late-owner", resource: "issue:CORE-LATE")
      # The event lands while triage is considering the old terminal task.
      Coordination::TriageService.new(ai_runner: Object.new).send(:ingest_events, 50, Time.current)
      { "rulings" => [{ "task_id" => old.id, "status" => "inbox" }] }
    end
    result = Coordination::TriageService.new(ai_runner: ai).call
    expect(result.rejected).to eq(1)
    expect(old.reload.status).to eq("done")
    expect(feedback.reload.processed?).to eq(false)
    expect(event.reload.task_id == old.id).to eq(false)
    expect(Task.open_status.where(source_plugin: "github", source_resource_id: "issue:CORE-LATE").count).to eq(1)
  end
end

# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

test("task state machine allows documented transitions only") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    task = Task.create!(title: "t", status: "inbox")

    expect(Task.transition_allowed?("inbox", "ready")).to eq(true)
    expect(Task.transition_allowed?("inbox", "done")).to eq(false)
    expect(Task.transition_allowed?("ready", "running")).to eq(true)
    expect(Task.transition_allowed?("running", "ready")).to eq(false)

    task.transition_to!("ready")
    expect(task.status).to eq("ready")

    rejected = nil
    begin
      task.transition_to!("inbox")
    rescue ActiveRecord::RecordInvalid => e
      rejected = e
    end
    expect(rejected.nil?).to eq(false)
    expect(task.reload.status).to eq("ready")
  end
end

test("follow-up human events attach feedback to the same task") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    first = WorkflowFakes::FakePluginRegistry.human_event(event_id: "evt-1", fingerprint: "fp-1")
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: { "owner/repo" => [first] })
    poller = Interaction::PollService.new(registry: registry, event_sink: sink)
    triage = Coordination::TriageService.new(ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: sink)

    poller.call(plugin: "github", scope: "owner/repo")
    triage.call
    expect(Task.count).to eq(1)
    task = Task.last

    followup = WorkflowFakes::FakePluginRegistry.human_event(
      event_id: "evt-2", fingerprint: "fp-2", body: "actually this is urgent"
    )
    registry2 = WorkflowFakes::FakePluginRegistry.new(events_by_scope: { "owner/repo" => [followup] })
    Interaction::PollService.new(registry: registry2, event_sink: sink).call(
      plugin: "github", scope: "owner/repo"
    )
    triage.call

    expect(Task.count).to eq(1)
    task.reload
    expect(task.task_feedbacks.count).to eq(1)
    expect(task.task_feedbacks.first.body).to eq("actually this is urgent")
  end
end

test("feedback never mutates the task until coordination triages it") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = Task.create!(title: "t", status: "inbox", priority: 0,
                        source_plugin: "github", source_resource_id: "issue-9")

    # Controllers persist feedback only; the task row is untouched.
    TaskFeedback.create!(task: task, body: "raise priority please",
                         author: "alice", suggested_priority: 42)
    expect(task.reload.priority).to eq(0)
    expect(task.status).to eq("inbox")

    LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    ai = WorkflowFakes::FakeAiRunner.new(
      answers: { "coordination" => { "rulings" => [
        { "task_id" => task.id, "priority" => 42, "status" => "ready" }
      ] } }
    )
    Coordination::TriageService.new(ai_runner: ai, event_sink: sink).call

    expect(task.reload.priority).to eq(42)
    expect(task.status).to eq("ready")
    expect(task.task_feedbacks.unprocessed.count).to eq(0)
  end
end

test("unknown tasks and transitions in AI rulings are rejected") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    task = Task.create!(title: "t", status: "inbox", priority: 0)
    LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    ai = WorkflowFakes::FakeAiRunner.new(
      answers: { "coordination" => { "rulings" => [
        { "task_id" => 999_999, "priority" => 5 },
        { "task_id" => task.id, "status" => "done" }
      ] } }
    )

    result = Coordination::TriageService.new(ai_runner: ai, event_sink: sink).call

    expect(result.triaged).to eq(0)
    expect(result.rejected).to eq(2)
    expect(task.reload.status).to eq("inbox")
    expect(task.priority).to eq(0)
  end
end

test("unconfigured coordination provider backs off visibly instead of storming") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    Task.create!(title: "t", status: "inbox")
    LayerPolicy.create!(layer: "coordination", provider: "muse", enabled: true)
    ai = WorkflowFakes::FakeAiRunner.new(
      errors: { "coordination" => WorkflowFakes::FakeNotConfigured.new("cli login missing") }
    )

    result = Coordination::TriageService.new(ai_runner: ai, event_sink: sink).call

    expect(result.triaged).to eq(0)
    task = Task.last
    expect(task.last_error.include?("provider_not_configured")).to eq(true)
    expect(task.next_action_at.nil?).to eq(false)
    expect(sink.kinds.include?("triage.ai_failed")).to eq(true)
  end
end

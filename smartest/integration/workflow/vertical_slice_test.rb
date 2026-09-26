# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

# End-to-end deterministic flow with fake ports and real PostgreSQL:
# poll -> inbox -> triage (coordination AI) -> ready/running -> leased run
# (execution queue job logic) -> completion through coordinator -> outbound
# action delivered via interaction (with the interaction policy drafting).
test("inbox to outbound vertical slice progresses through every layer") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo,github:issue-1") do |root|
    sink = WorkflowFakes::FakeEventSink.new
    registry = WorkflowFakes::FakePluginRegistry.new(
      events_by_scope: {
        "owner/repo" => [WorkflowFakes::FakePluginRegistry.human_event(body: "please fix the login bug")]
      }
    )
    answers = {}
    ai = WorkflowFakes::FakeAiRunner.new(answers: answers)

    # 1. Poll persists the durable inbox event and commits the cursor.
    poll = Interaction::PollService.new(registry: registry, event_sink: sink).call(
      plugin: "github", scope: "owner/repo"
    )
    expect(poll.ok).to eq(true)
    expect(ExternalEvent.count).to eq(1)
    expect(IntegrationCursor.find_by(plugin: "github", scope: "owner/repo").cursor).to eq(
      { "next" => "cursor-owner/repo-2" }
    )

    # 2. Triage without a coordination policy ingests deterministically but
    # leaves the task in inbox (no silent fallback).
    triage = Coordination::TriageService.new(ai_runner: ai, event_sink: sink)
    first = triage.call
    expect(first.ingested).to eq(1)
    task = Task.last
    expect(task.status).to eq("inbox")

    # 3. Coordination AI prioritizes, readies, and dispatches the task.
    LayerPolicy.create!(layer: "coordination", provider: "codex", enabled: true)
    LayerPolicy.create!(layer: "execution", provider: "codex", enabled: true)
    LayerPolicy.create!(layer: "interaction", provider: "codex", enabled: true)
    answers["coordination"] = {
      "rulings" => [{ "task_id" => task.id, "priority" => 10, "status" => "ready", "dispatch" => true }]
    }
    answers["execution"] = { "outcome" => "waiting_review", "summary" => "fixed login",
                             "reply_body" => "login fixed, please verify" }
    answers["interaction"] = { "body" => "drafted: login fixed, please verify" }

    second = triage.call
    expect(second.triaged).to eq(1)
    task.reload
    expect(task.status).to eq("running")
    expect(task.priority).to eq(10)
    run = TaskRun.last
    expect(run.status).to eq("pending")
    expect(run.provider).to eq("codex")

    # 4. The execution-queue logic leases the persisted run and completes
    # through the coordinator ( fencing token required ).
    exec_result = Execution::RunnerService.new(ai_runner: ai, event_sink: sink).call(run.id)
    expect(exec_result.ok).to eq(true)
    run.reload
    task.reload
    expect(run.status).to eq("succeeded")
    expect(task.status).to eq("waiting_review")
    expect(Dir.exist?(File.join(root, "task_#{task.id}", "run_#{run.id}"))).to eq(true)
    action = OutboundAction.last
    expect(action.status).to eq("pending")

    # 5. Interaction delivers the outbound action, using the enabled
    # interaction policy to draft the human-facing body.
    delivery = Interaction::OutboundService.new(registry: registry, ai_runner: ai,
                                                event_sink: sink).call(action.id)
    expect(delivery.ok).to eq(true)
    action.reload
    expect(action.status).to eq("sent")
    expect(action.external_id).to eq("ext-1")
    expect(registry.sent.last[:input]["body"]).to eq("drafted: login fixed, please verify")

    # Every layer emitted structured events; AI ran on every layer.
    %w[poll.completed triage.completed run.leased run.completed outbound.sent].each do |kind|
      expect(sink.kinds.include?(kind)).to eq(true)
    end
    expect(ai.calls.map { |c| c[:layer] }.sort).to eq(%w[coordination execution interaction])
  end
end

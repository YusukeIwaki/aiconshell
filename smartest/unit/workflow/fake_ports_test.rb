# frozen_string_literal: true

require "test_helper"

# Unit suite: the deterministic test doubles behave like the documented port
# signatures (invoke/call keywords and return shapes) without Rails or I/O.
test("fake plugin registry serves scripted latest_events and captures sends") do
  registry = WorkflowFakes::FakePluginRegistry.new(
    events_by_scope: {
      "owner/repo" => [WorkflowFakes::FakePluginRegistry.human_event]
    }
  )

  latest = registry.invoke(plugin: "github", operation: "latest_events",
                           input: { "scope" => "owner/repo", "cursor" => nil }, context: {})
  sent = registry.invoke(plugin: "github", operation: "reply",
                         input: { "resource_id" => "issue-1", "body" => "hi" }, context: {})

  expect(latest["events"].size).to eq(1)
  expect(latest["events"].first["actor_type"]).to eq("human")
  expect(latest["cursor"]).to eq({ "next" => "cursor-owner/repo-2" })
  expect(sent["external_id"]).to eq("ext-1")
  expect(registry.invocations.size).to eq(2)
  expect(registry.sent.size).to eq(1)
end

test("fake AI runner returns the programmed answer per layer") do
  runner = WorkflowFakes::FakeAiRunner.new(
    answers: { "coordination" => { "rulings" => [] }, "execution" => { "outcome" => "done" } }
  )

  coordination = runner.call(provider: "codex", prompt: "triage", schema: {},
                             workspace: "/tmp/ws", layer: "coordination")
  execution = runner.call(provider: "codex", prompt: "work", schema: {},
                          workspace: "/tmp/ws", layer: "execution")

  expect(coordination).to eq({ "rulings" => [] })
  expect(execution).to eq({ "outcome" => "done" })
  expect(runner.calls.map { |c| c[:layer] }).to eq(%w[coordination execution])
end

test("fake AI runner raises scripted errors for failure-path tests") do
  runner = WorkflowFakes::FakeAiRunner.new(errors: { "execution" => WorkflowFakes::FakeNotConfigured.new("cli missing") })

  raised = nil
  begin
    runner.call(provider: "muse", prompt: "work", schema: {}, workspace: "/tmp/ws", layer: "execution")
  rescue WorkflowFakes::FakeNotConfigured => e
    raised = e
  end

  expect(raised.nil?).to eq(false)
  expect(raised.message).to eq("cli missing")
end

test("fake event sink captures structured emissions") do
  sink = WorkflowFakes::FakeEventSink.new
  sink.emit(layer: "coordination", kind: "triage.completed", message: "done", task_id: 7)

  expect(sink.kinds).to eq(["triage.completed"])
  expect(sink.events.first[:task_id]).to eq(7)
end

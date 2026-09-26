# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

test("duplicate polls are idempotent and keep the cursor committed") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    event = WorkflowFakes::FakePluginRegistry.human_event
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: { "owner/repo" => [event] })
    sink = WorkflowFakes::FakeEventSink.new
    poller = Interaction::PollService.new(registry: registry, event_sink: sink)

    first = poller.call(plugin: "github", scope: "owner/repo")
    second = poller.call(plugin: "github", scope: "owner/repo")

    expect(first.ok).to eq(true)
    expect(second.ok).to eq(true)
    expect(ExternalEvent.count).to eq(1)
    cursor = IntegrationCursor.find_by(plugin: "github", scope: "owner/repo")
    expect(cursor.cursor).to eq({ "next" => "cursor-owner/repo-2" })
    expect(cursor.last_error).to eq(nil)
  end
end

test("bot events are persisted but never become tasks") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    registry = WorkflowFakes::FakePluginRegistry.new(
      events_by_scope: { "owner/repo" => [WorkflowFakes::FakePluginRegistry.bot_event] }
    )
    sink = WorkflowFakes::FakeEventSink.new

    Interaction::PollService.new(registry: registry, event_sink: sink).call(
      plugin: "github", scope: "owner/repo"
    )
    result = Coordination::TriageService.new(
      ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: sink
    ).call

    expect(ExternalEvent.count).to eq(1)
    expect(ExternalEvent.last.processed?).to eq(true)
    expect(result.ingested).to eq(0)
    expect(Task.count).to eq(0)
  end
end

test("non-allowlisted scopes are rejected visibly without retry storms") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: {})
    sink = WorkflowFakes::FakeEventSink.new

    result = Interaction::PollService.new(registry: registry, event_sink: sink).call(
      plugin: "github", scope: "evil/other"
    )

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:scope_not_allowed)
    expect(result.retryable).to eq(false)
    expect(registry.invocations).to eq([])
    cursor = IntegrationCursor.find_by(plugin: "github", scope: "evil/other")
    expect(cursor.last_error.include?("allowlist")).to eq(true)
  end
end

test("invalid events keep valid rows but hold the cursor for retry") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    registry = WorkflowFakes::FakePluginRegistry.new(
      events_by_scope: {
        "owner/repo" => [
          WorkflowFakes::FakePluginRegistry.human_event,
          { "event_id" => "broken", "payload" => {} }
        ]
      }
    )
    sink = WorkflowFakes::FakeEventSink.new

    result = Interaction::PollService.new(registry: registry, event_sink: sink).call(
      plugin: "github", scope: "owner/repo"
    )

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:invalid_events)
    expect(result.retryable).to eq(true)
    expect(ExternalEvent.count).to eq(1)
    cursor = IntegrationCursor.find_by(plugin: "github", scope: "owner/repo")
    expect(cursor.cursor).to eq(nil)
    expect(cursor.last_error.nil?).to eq(false)
  end
end

test("overlapping polls are skipped while a lease is held") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:owner/repo") do |_root|
    IntegrationCursor.create!(plugin: "github", scope: "owner/repo",
                              lease_token: "held", lease_expires_at: 5.minutes.from_now)
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: {})
    sink = WorkflowFakes::FakeEventSink.new

    result = Interaction::PollService.new(registry: registry, event_sink: sink).call(
      plugin: "github", scope: "owner/repo"
    )

    expect(result.ok).to eq(true)
    expect(result.code).to eq(:lease_skipped)
    expect(registry.invocations).to eq([])
  end
end

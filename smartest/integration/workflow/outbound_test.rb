# frozen_string_literal: true

require "db_helper"
require_relative "workflow_test_helper"

test("outbound delivery validates scope allowlist and input schema") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: {})
    sender = Interaction::OutboundService.new(registry: registry,
                                              ai_runner: WorkflowFakes::FakeAiRunner.new,
                                              event_sink: sink)
    task = Task.create!(title: "t", status: "waiting_review",
                        source_plugin: "github", source_resource_id: "issue-1")

    forbidden = OutboundAction.create!(
      plugin: "github", operation: "reply",
      input: { "resource_id" => "issue-9", "scope" => "issue-9", "body" => "hi" },
      idempotency_key: "key-forbidden", status: "pending", task: task
    )
    expect(sender.call(forbidden.id).code).to eq(:scope_not_allowed)
    expect(forbidden.reload.status).to eq("failed")
    expect(registry.sent).to eq([])

    invalid = OutboundAction.create!(
      plugin: "github", operation: "reply",
      input: { "resource_id" => "issue-1", "scope" => "issue-1", "body" => "  " },
      idempotency_key: "key-invalid", status: "pending", task: task
    )
    expect(sender.call(invalid.id).code).to eq(:input_invalid)
    expect(invalid.reload.status).to eq("failed")
    expect(registry.sent).to eq([])
  end
end

test("outbound delivery without an interaction policy sends the body as-is") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: {})
    ai = WorkflowFakes::FakeAiRunner.new
    task = Task.create!(title: "t", status: "waiting_review",
                        source_plugin: "github", source_resource_id: "issue-1")
    action = OutboundAction.create!(
      plugin: "github", operation: "reply",
      input: { "resource_id" => "issue-1", "scope" => "issue-1", "body" => "plain body" },
      idempotency_key: "key-plain", status: "pending", task: task
    )

    result = Interaction::OutboundService.new(registry: registry, ai_runner: ai,
                                              event_sink: sink).call(action.id)

    expect(result.ok).to eq(true)
    expect(action.reload.status).to eq("sent")
    expect(registry.sent.last[:input]["body"]).to eq("plain body")
    expect(ai.calls).to eq([])
  end
end

test("transient send failures stay retryable and visible") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    registry = WorkflowFakes::FakePluginRegistry.new(
      events_by_scope: {},
      errors: { "github#reply" => WorkflowFakes::FakeTransportError.new("connection reset") }
    )
    task = Task.create!(title: "t", status: "waiting_review",
                        source_plugin: "github", source_resource_id: "issue-1")
    action = OutboundAction.create!(
      plugin: "github", operation: "reply",
      input: { "resource_id" => "issue-1", "scope" => "issue-1", "body" => "hi" },
      idempotency_key: "key-retry", status: "pending", task: task
    )

    result = Interaction::OutboundService.new(
      registry: registry, ai_runner: WorkflowFakes::FakeAiRunner.new, event_sink: sink
    ).call(action.id)

    expect(result.ok).to eq(false)
    expect(result.code).to eq(:transient_error)
    expect(action.reload.status).to eq("pending")
    expect(action.attempts).to eq(1)
    expect(action.error.nil?).to eq(false)
    expect(sink.kinds.include?("outbound.retryable")).to eq(true)
  end
end

test("duplicate deliveries are rejected once the action leaves pending") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    sink = WorkflowFakes::FakeEventSink.new
    registry = WorkflowFakes::FakePluginRegistry.new(events_by_scope: {})
    sender = Interaction::OutboundService.new(registry: registry,
                                              ai_runner: WorkflowFakes::FakeAiRunner.new,
                                              event_sink: sink)
    task = Task.create!(title: "t", status: "waiting_review",
                        source_plugin: "github", source_resource_id: "issue-1")
    action = OutboundAction.create!(
      plugin: "github", operation: "reply",
      input: { "resource_id" => "issue-1", "scope" => "issue-1", "body" => "hi" },
      idempotency_key: "key-dupe", status: "pending", task: task
    )

    expect(sender.call(action.id).ok).to eq(true)
    expect(sender.call(action.id).code).to eq(:duplicate_delivery)
    expect(registry.sent.size).to eq(1)
  end
end

test("idempotency keys de-duplicate action creation") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "github:issue-1") do |_root|
    task = Task.create!(title: "t", status: "waiting_review")
    OutboundAction.create!(plugin: "github", operation: "reply",
                           input: { "resource_id" => "issue-1", "body" => "hi" },
                           idempotency_key: "key-once", status: "pending", task: task)
    dupe = OutboundAction.new(plugin: "github", operation: "reply",
                              input: { "resource_id" => "issue-1", "body" => "hi" },
                              idempotency_key: "key-once", status: "pending", task: task)

    expect(dupe.valid?).to eq(false)
  end
end

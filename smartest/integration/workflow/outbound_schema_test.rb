# frozen_string_literal: true

require "db_helper"
require "aiconshell/plugins"
require_relative "workflow_test_helper"

# Outbound delivery validates the EXACT registered plugin schemas (issue #11,
# pass 2). Real PostgreSQL plus a real Registry with a strict custom plugin;
# no network.
class CustomSchemaReplyPlugin < Aiconshell::Plugins::Base
  plugin_id "custom"
  operation "reply",
            input_schema: {
              "type" => "object", "required" => %w[resource_id body ticket_ref],
              "properties" => {
                "resource_id" => { "type" => "string", "minLength" => 1 },
                "body" => { "type" => "string", "minLength" => 1 },
                "ticket_ref" => { "type" => "string", "minLength" => 1 }
              },
              "additionalProperties" => false
            },
            output_schema: Aiconshell::Plugins::Schemas::WRITE_OUTPUT,
            scope: "custom:write"

  attr_reader :handled

  def initialize
    @handled = []
  end

  private

  def handle_reply(input, _context)
    @handled << input
    { "external_id" => "custom-#{@handled.size}", "url" => nil }
  end
end

class CustomSchemaRecordingTransport
  attr_reader :calls

  def initialize
    @calls = []
  end

  def request(**request)
    @calls << request
    raise "transport must not be used"
  end
end

def custom_schema_delivery(plugin:, transport:)
  registry = Aiconshell::Plugins::Registry.new(env: {}, transport: transport).register(plugin)
  Interaction::OutboundService.new(registry: registry,
                                   ai_runner: WorkflowFakes::FakeAiRunner.new,
                                   event_sink: WorkflowFakes::FakeEventSink.new)
end

test("action validation rejects malformed types and impossible builtin write targets before I/O") do |db:|
  with_workflow_env(scopes: "discord:channel/123456789012345678") do
    transport = CustomSchemaRecordingTransport.new
    registry = Aiconshell::Plugins::Registry.new(env: {}, transport: transport).register(Aiconshell::Plugins::Discord.new)
    validator = Interaction::ActionValidator.new(registry: registry)
    expect(validator.validate(plugin: "discord", operation: "send_message", input: "invalid").code).to eq(:input_invalid)
    expect(validator.validate(plugin: "discord", operation: "send_message",
      input: { "scope" => "channel:abc", "body" => "hello" }).code).to eq(:input_invalid)
    expect(validator.validate(plugin: "discord", operation: "send_message",
      input: { "scope" => "channel:123456789012345678", "body" => "hello" }).ok?).to eq(true)
    expect(transport.calls).to eq([])
  end
end

test("custom required input fields survive delivery") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "custom:scope-1") do
    plugin = CustomSchemaReplyPlugin.new
    transport = CustomSchemaRecordingTransport.new
    sender = custom_schema_delivery(plugin: plugin, transport: transport)
    action = OutboundAction.create!(
      plugin: "custom", operation: "reply",
      input: { "resource_id" => "scope-1", "body" => "status update", "ticket_ref" => "T-123" },
      idempotency_key: "custom-schema-1", status: "pending")

    outcome = sender.call(action.id)

    expect(outcome.ok).to eq(true)
    expect(action.reload.status).to eq("sent")
    expect(action.external_id).to eq("custom-1")
    expect(plugin.handled).to eq([
      { "resource_id" => "scope-1", "body" => "status update", "ticket_ref" => "T-123" }
    ])
    expect(transport.calls).to eq([])
  end
end

test("malformed unexpected input is rejected before the handler") do |db:|
  expect(db.transaction_open?).to eq(true)
  with_workflow_env(scopes: "custom:scope-1") do
    plugin = CustomSchemaReplyPlugin.new
    transport = CustomSchemaRecordingTransport.new
    sender = custom_schema_delivery(plugin: plugin, transport: transport)

    extra = OutboundAction.create!(
      plugin: "custom", operation: "reply",
      input: { "resource_id" => "scope-1", "body" => "status update",
               "ticket_ref" => "T-123", "bogus" => "nope" },
      idempotency_key: "custom-schema-2", status: "pending")
    expect(sender.call(extra.id).code).to eq(:input_invalid)
    expect(extra.reload.status).to eq("failed")

    missing = OutboundAction.create!(
      plugin: "custom", operation: "reply",
      input: { "resource_id" => "scope-1", "body" => "status update" },
      idempotency_key: "custom-schema-3", status: "pending")
    expect(sender.call(missing.id).code).to eq(:input_invalid)
    expect(missing.reload.status).to eq("failed")

    expect(plugin.handled).to eq([])
    expect(transport.calls).to eq([])
  end
end

# frozen_string_literal: true

require "test_helper"
require "event_log_fixtures"

TeamsSink = Aiconshell::Observability::TeamsSink
FakeRegistry = EventLogTestSupport::FakePluginsRegistry

def teams_record(channel: "ops")
  { "teams_channel" => channel,
    "envelope" => EventLogTestSupport.build_envelope(message: "Deploy finished") }
end

test("delivers through the plugins port with a compact body") do |test_logger:|
  registry = FakeRegistry.new
  sink = TeamsSink.new(registry:, logger: test_logger)

  expect(sink.enabled?).to eq(true)
  expect(sink.deliver(teams_record)).to eq(:delivered)

  call = registry.invocations.first
  expect(call[:plugin]).to eq("teams")
  expect(call[:operation]).to eq("send_message")
  expect(call[:input]["scope"]).to eq("ops")
  expect(call[:input]["body"]).to match(/\[coordination\/task\.prioritized\] Deploy finished/)
  expect(call[:context]["source"]).to eq("event_log")
end

test("is disabled without a registry or when the plugin is unconfigured") do
  expect(TeamsSink.new.deliver(teams_record)).to eq(:skipped)

  registry = FakeRegistry.new(catalog: [{ "id" => "teams", "configured" => false }])
  sink = TeamsSink.new(registry:)
  expect(sink.enabled?).to eq(false)
  expect(sink.deliver(teams_record)).to eq(:skipped)
  expect(registry.invocations).to eq([])
end

test("skips records without a channel without touching the registry") do
  registry = FakeRegistry.new
  sink = TeamsSink.new(registry:)

  expect(sink.deliver(teams_record(channel: nil))).to eq(:skipped)
  expect(registry.invocations).to eq([])
end

test("plugin failures raise sanitized SinkError (logged, never emitted)") do |test_logger:, log_output:|
  registry = FakeRegistry.new(error: RuntimeError.new("403 token=zzz"))
  sink = TeamsSink.new(registry:, logger: test_logger)

  begin
    sink.deliver(teams_record)
    raise "expected SinkError"
  rescue Aiconshell::Observability::SinkError => e
    expect(e.message).not_to match(/zzz/)
    expect(e.message).to match(/teams delivery failed/)
  end
  expect(registry.invocations.size).to eq(1)
  expect(log_output.string).to eq("")
end

test("format_message truncates long bodies") do
  envelope = EventLogTestSupport.build_envelope(message: "m" * 2000)

  expect(TeamsSink.format_message(envelope).length).to eq(1000)
end

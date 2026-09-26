# frozen_string_literal: true

require "test_helper"
require "event_log_fixtures"

Observability = Aiconshell::Observability

test("emit stores a redacted envelope in the outbox without network I/O") do |memory_outbox:, test_logger:, fixed_clock:|
  Observability.configure do |config|
    config.outbox = memory_outbox
    config.logger = test_logger
    config.clock = fixed_clock
  end

  envelope = Observability.emit(
    layer: "coordination", kind: "task.prioritized", message: "done",
    data: { "token" => "secret" }, teams_channel: "ops"
  )

  expect(envelope["data"]).to eq({ "token" => "[REDACTED]" })
  record = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(record["teams_channel"]).to eq("ops")
  expect(record["envelope"]["message"]).to eq("done")
end

test("emit never raises: invalid input is dropped with a sanitized warning") do |memory_outbox:, test_logger:, log_output:|
  Observability.configure do |config|
    config.outbox = memory_outbox
    config.logger = test_logger
  end

  result = Observability.emit(layer: "bogus", kind: "x", message: "m token=zzz")

  expect(result).to be_nil
  expect(memory_outbox.size).to eq(0)
  expect(log_output.string).not_to match(/zzz/)
  expect(log_output.string).to match(/emit dropped/)
end

test("configured Teams channel receives events from every layer") do |memory_outbox:|
  Observability.configure do |config|
    config.outbox = memory_outbox
    config.default_teams_channel = "channel:team/operations"
  end

  %w[interaction coordination execution].each do |layer|
    envelope = Observability.emit(layer: layer, kind: "work.updated", message: "Updated")
    record = memory_outbox.find_by_event_id(envelope["event_id"])
    expect(record["teams_channel"]).to eq("channel:team/operations")
  end
end

test("emit never raises: outbox failures are contained") do |test_logger:, log_output:|
  broken = Object.new
  def broken.enqueue(*)
    raise IOError, "connection refused password=supersecret"
  end
  Observability.configure do |config|
    config.outbox = broken
    config.logger = test_logger
  end

  expect(Observability.emit(layer: "coordination", kind: "a.b", message: "m")).to be_nil
  expect(log_output.string).not_to match(/supersecret/)
end

test("emit! raises ValidationError for strict callers") do |memory_outbox:|
  Observability.configure { |config| config.outbox = memory_outbox }

  expect(-> { Observability.emit!(layer: "bogus", kind: "x", message: "m") })
    .to raise_error(Aiconshell::Observability::ValidationError)
end

test("emit contains a simultaneous outbox and diagnostic logger failure") do
  broken_logger = Object.new
  def broken_logger.warn(*) = raise(IOError, "log device unavailable")
  Observability.configure { |config| config.logger = broken_logger }

  expect(Observability.emit(layer: "invalid", kind: "x", message: "m")).to be_nil
end

test("search delegates to the configured backend") do
  backend = EventLogTestSupport::FakeSearchBackend.new([{ "event_id" => "e1" }])
  Observability.configure { |config| config.search_backend = backend }

  results = Observability.search(query: "hi", layer: "coordination", limit: 10)

  expect(results).to eq([{ "event_id" => "e1" }])
  expect(backend.calls.first[:query]).to eq("hi")
  expect(backend.calls.first[:limit]).to eq(10)

  Observability.search(event_id: "e1")
  expect(backend.calls.last[:event_id]).to eq("e1")
end

test("search without a backend raises NotConfiguredError") do
  expect(-> { Observability.search(query: "hi") })
    .to raise_error(Aiconshell::Observability::NotConfiguredError)
end

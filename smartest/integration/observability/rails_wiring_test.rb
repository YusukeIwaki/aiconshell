# frozen_string_literal: true

require "integration/observability_helper"

test("Rails boot wires the outbox port to ActiveRecord, never MemoryOutbox") do |db:, observability_config:|
  expect(Aiconshell::Observability.config.outbox).to be_a(EventLogging::OutboxAdapter)
  expect(Aiconshell::Observability.config.outbox).not_to be_a(Aiconshell::Observability::MemoryOutbox)
end

test("real Rails emit persists a redacted envelope to event_deliveries") do |db:, observability_config:|
  envelope = EventLogging::Emitter.emit!(
    layer: "coordination", kind: "task.prioritized", message: "Priority updated",
    task_id: 7, correlation_id: "corr-123", data: { "token" => "secret" }
  )

  row = EventDelivery.find_by!(event_id: envelope["event_id"])
  expect(row.envelope["data"]).to eq({ "token" => "[REDACTED]" })
  expect(row.layer).to eq("coordination")
  expect(EventLogging::OutboxAdapter.new.find_by_event_id(envelope["event_id"])["id"]).to eq(row.id)
end

test("search uses the configured backend; unconfigured raises, never silent memory") do |db:, observability_config:|
  backend = EventLogTestSupport::FakeSearchBackend.new([{ "event_id" => "e1" }])
  Aiconshell::Observability.configure { |config| config.search_backend = backend }

  expect(EventLogging::Search.search(query: "hi")).to eq([{ "event_id" => "e1" }])
  expect(backend.calls.first[:query]).to eq("hi")

  Aiconshell::Observability.configure { |config| config.search_backend = nil }
  expect(-> { EventLogging::Search.search(query: "hi") })
    .to raise_error(Aiconshell::Observability::NotConfiguredError)
end

test("ClickHouse adapter is built from ENV without network I/O at boot") do |db:, observability_config:|
  saved = ENV.to_h.slice("CLICKHOUSE_URL", "CLICKHOUSE_DATABASE", "CLICKHOUSE_TABLE",
                         "CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD")
  begin
    ENV.delete("CLICKHOUSE_URL")
    expect(EventLogging::Delivery.clickhouse_adapter).to be_nil

    ENV["CLICKHOUSE_URL"] = "http://ch:8123"
    ENV.delete("CLICKHOUSE_DATABASE")
    adapter = EventLogging::Delivery.clickhouse_adapter
    expect(adapter.base_url).to eq("http://ch:8123")
    expect(adapter.database).to eq("aiconshell")
  ensure
    %w[CLICKHOUSE_URL CLICKHOUSE_DATABASE CLICKHOUSE_TABLE CLICKHOUSE_USER CLICKHOUSE_PASSWORD].each do |key|
      saved.key?(key) ? ENV.store(key, saved[key]) : ENV.delete(key)
    end
  end
end

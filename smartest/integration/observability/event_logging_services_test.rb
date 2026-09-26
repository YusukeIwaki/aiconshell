# frozen_string_literal: true

require "integration/observability_helper"

def with_env(overrides)
  saved = overrides.keys.to_h { |key| [key, ENV[key]] }
  overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  yield
ensure
  saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
end

test("Emitter delegates to the observability port without raising") do |observability_config:|
  memory_outbox = Aiconshell::Observability::MemoryOutbox.new(
    clock: EventLogTestSupport::FixedClock.new
  )
  Aiconshell::Observability.configure do |config|
    config.outbox = memory_outbox
    config.logger = Logger.new(File::NULL)
  end

  envelope = EventLogging::Emitter.emit(
    layer: "execution", kind: "run.started", message: "go", teams_channel: "ops"
  )

  expect(memory_outbox.find_by_event_id(envelope["event_id"])["teams_channel"]).to eq("ops")
  expect(EventLogging::Emitter.emit(layer: "bogus", kind: "x", message: "m")).to be_nil
  expect(-> { EventLogging::Emitter.emit!(layer: "bogus", kind: "x", message: "m") })
    .to raise_error(Aiconshell::Observability::ValidationError)
end

test("Search delegates to the configured backend") do |observability_config:|
  backend = EventLogTestSupport::FakeSearchBackend.new([{ "event_id" => "e1" }])
  Aiconshell::Observability.configure { |config| config.search_backend = backend }

  expect(EventLogging::Search.search(query: "x")).to eq([{ "event_id" => "e1" }])
end

test("OutboxAdapter implements the port over ActiveRecord") do |db:, observability_config:|
  adapter = EventLogging::OutboxAdapter.new
  now = Time.current
  envelope = EventLogTestSupport.build_envelope

  first = adapter.enqueue(envelope, teams_channel: "ops")
  second = adapter.enqueue(envelope, teams_channel: "ops")

  expect(second["id"]).to eq(first["id"])
  expect(EventDelivery.count).to eq(1)
  expect(adapter.pending("teams", limit: 10, now:).map { |r| r["id"] }).to eq([first["id"]])

  adapter.mark_failed(first["id"], "teams", error: "down", next_retry_at: now + 60)
  expect(adapter.pending("teams", limit: 10, now:)).to eq([])
  adapter.mark_delivered(first["id"], "teams", at: now + 61)
  adapter.mark_delivered(first["id"], "clickhouse", at: now + 61)

  found = adapter.find_by_event_id(envelope["event_id"])
  expect(found["teams"]["attempts"]).to eq(1)
  expect(found["clickhouse"]["delivered_at"]).not_to be_nil
  EventDelivery.where(id: first["id"]).update_all(created_at: now - 30 * 86_400)
  expect(adapter.prune(before: now - 7 * 86_400)).to eq(1)
end

test("Delivery reads ClickHouse config from ENV and tolerates missing plugins") do |observability_config:|
  with_env("CLICKHOUSE_URL" => nil) do
    expect(EventLogging::Delivery.clickhouse_adapter).to be_nil
  end
  with_env("CLICKHOUSE_URL" => "http://ch:8123", "CLICKHOUSE_DATABASE" => nil,
           "CLICKHOUSE_TABLE" => nil, "CLICKHOUSE_USER" => nil, "CLICKHOUSE_PASSWORD" => nil) do
    adapter = EventLogging::Delivery.clickhouse_adapter
    expect(adapter.base_url).to eq("http://ch:8123")
    expect(adapter.database).to eq("aiconshell")
    expect(adapter.table).to eq("event_log")
  end
  expected_registry = defined?(Aiconshell::Plugins::Registry) ? Aiconshell::Plugins::Registry.default : nil
  expect(EventLogging::Delivery.plugins_registry.equal?(expected_registry)).to eq(true)
  expect(EventLogging::Delivery.teams_sink.enabled?).to eq(false)
end

test("Delivery service drains the ActiveRecord outbox end to end") do |db:, observability_config:|
  clock = EventLogTestSupport::FixedClock.new
  with_env("CLICKHOUSE_URL" => nil) do
    EventLogging::OutboxAdapter.new.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
    summary = EventLogging::Delivery.service(clock:).deliver_pending(batch_size: 10)

    # ClickHouse unconfigured: rows stay pending; Teams disabled: skipped.
    expect(summary.clickhouse).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 0 })
    expect(summary.teams).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 1 })
    expect(EventDelivery.teams_pending(clock.now + 3600).count).to eq(0)
    expect(EventDelivery.clickhouse_pending(clock.now + 3600).count).to eq(1)
  end
end

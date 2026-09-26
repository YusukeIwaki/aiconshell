# frozen_string_literal: true

require "event_log_helper"

# Pre-Rails shims: in the merged Rails app the real ApplicationJob exists and
# these guards stay inert.
EVENT_LOG_JOB_SHIMMED = !defined?(::ApplicationJob)
if EVENT_LOG_JOB_SHIMMED
  Object.const_set(:ApplicationJob, Class.new do
    class << self
      attr_reader :queue_name_for_test

      def queue_as(name)
        @queue_name_for_test = name
      end
    end

    def logger
      @logger ||= Logger.new(File::NULL)
    end
  end)
end

require File.join(REPO_ROOT, "app/services/event_logging/emitter.rb")
require File.join(REPO_ROOT, "app/services/event_logging/search.rb")
require File.join(REPO_ROOT, "app/services/event_logging/outbox_adapter.rb")
require File.join(REPO_ROOT, "app/services/event_logging/delivery.rb")
require File.join(REPO_ROOT, "app/jobs/event_log_delivery_job.rb")

def with_env(overrides)
  saved = overrides.keys.to_h { |key| [key, ENV[key]] }
  overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  yield
ensure
  saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
end

test("Emitter delegates to the observability port without raising") do |memory_outbox:, test_logger:|
  Aiconshell::Observability.configure do |config|
    config.outbox = memory_outbox
    config.logger = test_logger
  end

  envelope = EventLogging::Emitter.emit(
    layer: "execution", kind: "run.started", message: "go", teams_channel: "ops"
  )

  expect(memory_outbox.find_by_event_id(envelope["event_id"])["teams_channel"]).to eq("ops")
  expect(EventLogging::Emitter.emit(layer: "bogus", kind: "x", message: "m")).to be_nil
  expect(-> { EventLogging::Emitter.emit!(layer: "bogus", kind: "x", message: "m") })
    .to raise_error(Aiconshell::Observability::ValidationError)
end

test("Search delegates to the configured backend") do
  backend = EventLogTestSupport::FakeSearchBackend.new([{ "event_id" => "e1" }])
  Aiconshell::Observability.configure { |config| config.search_backend = backend }

  expect(EventLogging::Search.search(query: "x")).to eq([{ "event_id" => "e1" }])
end

test("OutboxAdapter implements the port over ActiveRecord") do |clean_event_deliveries:, fixed_clock:|
  adapter = EventLogging::OutboxAdapter.new
  now = fixed_clock.now
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

test("Delivery reads ClickHouse config from ENV and tolerates missing plugins") do
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
  expect(EventLogging::Delivery.plugins_registry).to be_nil
  expect(EventLogging::Delivery.teams_sink.enabled?).to eq(false)
end

test("Delivery service drains the ActiveRecord outbox end to end") do |clean_event_deliveries:, fixed_clock:|
  with_env("CLICKHOUSE_URL" => nil) do
    EventLogging::OutboxAdapter.new.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
    summary = EventLogging::Delivery.service(clock: fixed_clock).deliver_pending(batch_size: 10)

    # ClickHouse unconfigured: rows stay pending; Teams disabled: skipped.
    expect(summary.clickhouse).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 0 })
    expect(summary.teams).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 1 })
    expect(EventDelivery.teams_pending(fixed_clock.now + 3600).count).to eq(0)
    expect(EventDelivery.clickhouse_pending(fixed_clock.now + 3600).count).to eq(1)
  end
end

test("delivery job runs on the control queue and reports counts") do |clean_event_deliveries:, fixed_clock:|
  if EVENT_LOG_JOB_SHIMMED
    expect(EventLogDeliveryJob.queue_name_for_test).to eq(:control)
  else
    expect(EventLogDeliveryJob.queue_name).to eq("control")
  end

  with_env("CLICKHOUSE_URL" => nil) do
    EventLogging::OutboxAdapter.new.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
    result = EventLogDeliveryJob.new.perform(batch_size: 10, prune_retention_days: 7)

    expect(result["teams"]).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 1 })
    expect(result["pruned"]).to eq(0)
  end
end

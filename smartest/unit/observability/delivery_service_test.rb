# frozen_string_literal: true

require "test_helper"
require "event_log_fixtures"

DeliveryService = Aiconshell::Observability::DeliveryService

def delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse: nil)
  DeliveryService.new(
    outbox: memory_outbox,
    clickhouse: clickhouse || EventLogTestSupport::FakeClickHouseSink.new,
    logger: test_logger, clock: fixed_clock
  )
end

test("delivers the ClickHouse destination and marks it") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope)
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:)

  summary = service.deliver_pending

  expect(summary.clickhouse).to eq({ "delivered" => 1, "failed" => 0, "skipped" => 0 })
  expect(clickhouse.inserted).to eq([envelope])

  record = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(record["clickhouse"]["delivered_at"]).to eq(fixed_clock.now.utc)
end

test("delivered rows are not re-inserted on retry") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope)
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:)

  first = service.deliver_pending
  expect(first.clickhouse["delivered"]).to eq(1)

  fixed_clock.advance_by(3600)
  second = service.deliver_pending

  expect(second.clickhouse).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 0 })
  expect(clickhouse.inserted.size).to eq(1)
end

test("clickhouse failure backs off and stays pending") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope)
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new(error: RuntimeError.new("ch down"))
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:)

  summary = service.deliver_pending

  expect(summary.clickhouse["failed"]).to eq(1)

  record = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(record["clickhouse"]["attempts"]).to eq(1)
  expect(record["clickhouse"]["next_retry_at"]).to eq(fixed_clock.now.utc + 120)
  expect(record["clickhouse"]["last_error"]).to eq("RuntimeError")
end

test("retry delay doubles per attempt up to the cap") do
  expect(DeliveryService.retry_delay_seconds(1)).to eq(120)
  expect(DeliveryService.retry_delay_seconds(2)).to eq(240)
  expect(DeliveryService.retry_delay_seconds(3)).to eq(480)
  expect(DeliveryService.retry_delay_seconds(100)).to eq(21_600)
end

test("prune removes only old, fully terminal rows") do |memory_outbox:, test_logger:, fixed_clock:|
  delivered = EventLogTestSupport.build_envelope(message: "old done")
  memory_outbox.enqueue(delivered)
  pending = EventLogTestSupport.build_envelope(message: "new")
  memory_outbox.enqueue(pending)
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:)

  service.deliver_pending
  # New row stays (both delivered just now, too fresh to prune).
  expect(service.prune(retention_days: 7)).to eq(0)

  fixed_clock.advance_by(8 * 86_400)
  expect(service.prune(retention_days: 7)).to eq(2)
  expect(memory_outbox.size).to eq(0)
end

test("prune keeps rows with a pending destination") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope)
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new(error: RuntimeError.new("down"))
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:)

  service.deliver_pending
  fixed_clock.advance_by(30 * 86_400)

  expect(service.prune(retention_days: 7)).to eq(0)
  expect(memory_outbox.size).to eq(1)
end

# Regression fake: listing blows up while inserts would work.
class PendingFailureOutbox
  def initialize(records, failing_destination)
    @records = records
    @failing_destination = failing_destination
    @marks = Hash.new { |hash, key| hash[key] = [] }
  end

  attr_reader :marks

  def pending(destination, limit:, now:)
    raise IOError, "#{destination} spool unreadable" if destination == @failing_destination

    @records.first(limit)
  end

  def mark_delivered(id, destination, at:)
    @marks["delivered-#{destination}"] << id
  end

  def mark_failed(id, destination, error:, next_retry_at:)
    @marks["failed-#{destination}"] << id
  end

  def mark_skipped(id, destination, reason:, at:)
    @marks["skipped-#{destination}"] << id
  end
end

test("pending listing failure is reported accurately") do |test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  record = { "id" => 1, "event_id" => envelope["event_id"], "envelope" => envelope,
             "clickhouse" => { "attempts" => 0 } }
  outbox = PendingFailureOutbox.new([record], "clickhouse")
  service = DeliveryService.new(outbox:, clickhouse: EventLogTestSupport::FakeClickHouseSink.new,
                                logger: test_logger, clock: fixed_clock)

  summary = service.deliver_pending

  expect(summary.clickhouse).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 0 })
  expect(summary.error).to match(/clickhouse/)
end

test("mark failures are counted without stopping the batch") do |test_logger:, fixed_clock:|
  envelopes = [EventLogTestSupport.build_envelope, EventLogTestSupport.build_envelope(message: "second")]
  records = envelopes.map.with_index(1) do |envelope, id|
    { "id" => id, "event_id" => envelope["event_id"], "envelope" => envelope,
      "clickhouse" => { "attempts" => 0 } }
  end
  outbox = PendingFailureOutbox.new(records, "never")
  def outbox.mark_delivered(id, destination, at:)
    raise IOError, "mark store down" if destination == "clickhouse"

    super
  end
  service = DeliveryService.new(outbox:, clickhouse: EventLogTestSupport::FakeClickHouseSink.new,
                                logger: test_logger, clock: fixed_clock)

  summary = service.deliver_pending

  # Both ClickHouse marks failed (counted).
  expect(summary.clickhouse).to eq({ "delivered" => 0, "failed" => 2, "skipped" => 0 })
  expect(summary.error).to be_nil
end

test("rows give up as skipped after MAX_ATTEMPTS failures") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  record = memory_outbox.enqueue(envelope)
  (DeliveryService::MAX_ATTEMPTS - 1).times do
    memory_outbox.mark_failed(record["id"], "clickhouse",
                              error: "down", next_retry_at: fixed_clock.now.utc)
  end
  service = delivery_service(
    memory_outbox:, test_logger:, fixed_clock:,
    clickhouse: EventLogTestSupport::FakeClickHouseSink.new(error: RuntimeError.new("still down"))
  )

  summary = service.deliver_pending

  expect(summary.clickhouse).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 1 })
  found = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(found["clickhouse"]["skipped_at"]).to eq(fixed_clock.now.utc)
  expect(memory_outbox.pending("clickhouse", limit: 10, now: fixed_clock.now.utc + 1_000_000)).to eq([])
end

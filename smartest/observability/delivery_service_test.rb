# frozen_string_literal: true

require "event_log_helper"

DeliveryService = Aiconshell::Observability::DeliveryService

def delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse: nil, teams: nil)
  DeliveryService.new(
    outbox: memory_outbox,
    clickhouse: clickhouse || EventLogTestSupport::FakeClickHouseSink.new,
    teams: teams || EventLogTestSupport::FakeTeamsSink.new,
    logger: test_logger, clock: fixed_clock
  )
end

test("delivers each destination independently and marks both") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope, teams_channel: "ops")
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new
  teams = EventLogTestSupport::FakeTeamsSink.new
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:, teams:)

  summary = service.deliver_pending

  expect(summary.clickhouse).to eq({ "delivered" => 1, "failed" => 0, "skipped" => 0 })
  expect(summary.teams).to eq({ "delivered" => 1, "failed" => 0, "skipped" => 0 })
  expect(clickhouse.inserted).to eq([envelope])
  expect(teams.delivered_records.size).to eq(1)

  record = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(record["clickhouse"]["delivered_at"]).to eq(fixed_clock.now.utc)
  expect(record["teams"]["delivered_at"]).to eq(fixed_clock.now.utc)
end

test("teams failure does not resend to clickhouse") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope, teams_channel: "ops")
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new
  teams = EventLogTestSupport::FakeTeamsSink.new(error: RuntimeError.new("teams down"))
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:, teams:)

  first = service.deliver_pending
  expect(first.clickhouse["delivered"]).to eq(1)
  expect(first.teams["failed"]).to eq(1)

  # Retry after backoff: only teams is attempted again.
  fixed_clock.advance_by(3600)
  teams.instance_variable_set(:@error, nil)
  second = service.deliver_pending

  expect(second.clickhouse).to eq({ "delivered" => 0, "failed" => 0, "skipped" => 0 })
  expect(second.teams["delivered"]).to eq(1)
  expect(clickhouse.inserted.size).to eq(1)
end

test("clickhouse failure backs off per destination and keeps teams flowing") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope, teams_channel: "ops")
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new(error: RuntimeError.new("ch down"))
  teams = EventLogTestSupport::FakeTeamsSink.new
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:, teams:)

  summary = service.deliver_pending

  expect(summary.clickhouse["failed"]).to eq(1)
  expect(summary.teams["delivered"]).to eq(1)

  record = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(record["clickhouse"]["attempts"]).to eq(1)
  expect(record["clickhouse"]["next_retry_at"]).to eq(fixed_clock.now.utc + 120)
  expect(record["clickhouse"]["last_error"]).to match(/ch down/)
end

test("disabled teams sink skips instead of retrying forever") do |memory_outbox:, test_logger:, fixed_clock:|
  envelope = EventLogTestSupport.build_envelope
  memory_outbox.enqueue(envelope, teams_channel: "ops")
  service = delivery_service(
    memory_outbox:, test_logger:, fixed_clock:,
    teams: EventLogTestSupport::FakeTeamsSink.new(enabled: false)
  )

  summary = service.deliver_pending

  expect(summary.teams["skipped"]).to eq(1)
  record = memory_outbox.find_by_event_id(envelope["event_id"])
  expect(record["teams"]["attempts"]).to eq(0)
end

test("records without a teams channel never touch teams") do |memory_outbox:, test_logger:, fixed_clock:|
  memory_outbox.enqueue(EventLogTestSupport.build_envelope)
  teams = EventLogTestSupport::FakeTeamsSink.new
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, teams:)

  summary = service.deliver_pending

  expect(summary.clickhouse["delivered"]).to eq(1)
  expect(teams.delivered_records).to eq([])
end

test("retry delay doubles per attempt up to the cap") do
  expect(DeliveryService.retry_delay_seconds(1)).to eq(120)
  expect(DeliveryService.retry_delay_seconds(2)).to eq(240)
  expect(DeliveryService.retry_delay_seconds(3)).to eq(480)
  expect(DeliveryService.retry_delay_seconds(100)).to eq(21_600)
end

test("prune removes only old, fully terminal rows") do |memory_outbox:, test_logger:, fixed_clock:|
  delivered = EventLogTestSupport.build_envelope(message: "old done")
  memory_outbox.enqueue(delivered, teams_channel: "ops")
  pending = EventLogTestSupport.build_envelope(message: "new")
  memory_outbox.enqueue(pending, teams_channel: "ops")
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
  memory_outbox.enqueue(envelope, teams_channel: "ops")
  clickhouse = EventLogTestSupport::FakeClickHouseSink.new(error: RuntimeError.new("down"))
  service = delivery_service(memory_outbox:, test_logger:, fixed_clock:, clickhouse:)

  service.deliver_pending
  fixed_clock.advance_by(30 * 86_400)

  expect(service.prune(retention_days: 7)).to eq(0)
  expect(memory_outbox.size).to eq(1)
end

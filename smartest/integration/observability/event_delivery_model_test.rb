# frozen_string_literal: true

require "integration/observability_helper"

def create_delivery!(overrides = {})
  envelope = EventLogTestSupport.build_envelope(
    message: overrides.delete(:message) || "hello",
    task_id: overrides.delete(:task_id) || 11
  )
  EventDelivery.create!(
    { event_id: envelope["event_id"], envelope:,
      layer: envelope["layer"], kind: envelope["kind"],
      task_id: envelope["task_id"], correlation_id: envelope["correlation_id"],
      occurred_at: envelope["occurred_at"] }.merge(overrides)
  )
end

test("validates presence and event_id uniqueness") do |db:|
  create_delivery!

  duplicate = EventDelivery.new(event_id: EventDelivery.first.event_id)
  expect(duplicate.valid?).to eq(false)
  expect(duplicate.errors[:event_id].any?).to eq(true)
  expect(EventDelivery.new.valid?).to eq(false)
end

test("clickhouse pending scope honors retry time") do |db:|
  now = Time.current
  ready = create_delivery!
  waiting = create_delivery!
  waiting.update!(clickhouse_next_retry_at: now + 3600)
  done = create_delivery!
  done.update!(clickhouse_delivered_at: now)

  expect(EventDelivery.clickhouse_pending(now).map(&:id)).to eq([ready.id])
  expect(EventDelivery.clickhouse_pending(now + 7200).map(&:id).sort).to eq([ready.id, waiting.id].sort)
end

test("prunable keeps fresh and pending rows") do |db:|
  now = Time.current
  old_done = create_delivery!
  old_done.update!(clickhouse_delivered_at: now - 30 * 86_400,
                   created_at: now - 30 * 86_400)
  old_skipped = create_delivery!
  old_skipped.update!(clickhouse_skipped_at: now - 30 * 86_400,
                      created_at: now - 30 * 86_400)
  old_pending = create_delivery!
  old_pending.update!(created_at: now - 30 * 86_400)
  fresh = create_delivery!
  fresh.update!(clickhouse_delivered_at: now)

  expect(EventDelivery.prunable(now - 7 * 86_400).map(&:id).sort)
    .to eq([old_done.id, old_skipped.id].sort)
  expect(old_pending.clickhouse_terminal?).to eq(false)
  expect(fresh.clickhouse_terminal?).to eq(true)
  expect(old_skipped.clickhouse_terminal?).to eq(true)
end

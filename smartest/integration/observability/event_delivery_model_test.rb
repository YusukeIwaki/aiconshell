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

test("pending scopes separate destinations and honor retry time") do |db:|
  now = Time.current
  ready = create_delivery!(teams_channel: "ops")
  no_teams = create_delivery!
  waiting = create_delivery!(teams_channel: "ops")
  waiting.update!(clickhouse_next_retry_at: now + 3600, teams_next_retry_at: now + 3600)
  done = create_delivery!(teams_channel: "ops")
  done.update!(clickhouse_delivered_at: now, teams_delivered_at: now)

  expect(EventDelivery.clickhouse_pending(now).map(&:id).sort).to eq([ready.id, no_teams.id].sort)
  expect(EventDelivery.teams_pending(now).map(&:id)).to eq([ready.id])
  expect(EventDelivery.teams_pending(now + 7200).map(&:id).sort).to eq([ready.id, waiting.id].sort)
end

test("prunable keeps fresh and pending rows") do |db:|
  now = Time.current
  old_done = create_delivery!(teams_channel: "ops")
  old_done.update!(clickhouse_delivered_at: now - 30 * 86_400, teams_delivered_at: now - 30 * 86_400,
                   created_at: now - 30 * 86_400)
  old_skipped = create_delivery!(teams_channel: "ops")
  old_skipped.update!(clickhouse_delivered_at: now - 30 * 86_400, teams_skipped_at: now - 30 * 86_400,
                      created_at: now - 30 * 86_400)
  old_ch_skipped = create_delivery!(teams_channel: "ops")
  old_ch_skipped.update!(clickhouse_skipped_at: now - 30 * 86_400, teams_delivered_at: now - 30 * 86_400,
                         created_at: now - 30 * 86_400)
  old_pending = create_delivery!(teams_channel: "ops")
  old_pending.update!(clickhouse_delivered_at: now - 30 * 86_400, created_at: now - 30 * 86_400)
  fresh = create_delivery!(teams_channel: "ops")
  fresh.update!(clickhouse_delivered_at: now, teams_delivered_at: now)

  expect(EventDelivery.prunable(now - 7 * 86_400).map(&:id).sort)
    .to eq([old_done.id, old_skipped.id, old_ch_skipped.id].sort)
  expect(old_pending.teams_terminal?).to eq(false)
  expect(old_skipped.teams_terminal?).to eq(true)
  expect(fresh.clickhouse_terminal?).to eq(true)
  expect(old_ch_skipped.clickhouse_terminal?).to eq(true)
  expect(fresh.teams_requested?).to eq(true)
  expect(create_delivery!.teams_requested?).to eq(false)
end

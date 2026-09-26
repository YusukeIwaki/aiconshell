# frozen_string_literal: true

require "event_log_helper"
require "aiconshell/observability/postgres_outbox"

PostgresOutbox = Aiconshell::Observability::PostgresOutbox

def pg_outbox(pg_connection)
  PostgresOutbox.new(pg_connection)
end

test("enqueue stores the envelope and is idempotent by event_id") do |pg_connection:, clean_event_deliveries:|
  outbox = pg_outbox(pg_connection)
  envelope = EventLogTestSupport.build_envelope

  first = outbox.enqueue(envelope, teams_channel: "ops")
  second = outbox.enqueue(envelope, teams_channel: "other")

  expect(first["event_id"]).to eq(envelope["event_id"])
  expect(second["id"]).to eq(first["id"])
  expect(second["envelope"]["message"]).to eq(envelope["message"])
  expect(second["teams_channel"]).to eq("ops")
  expect(pg_connection.exec("SELECT count(*) FROM event_deliveries")[0]["count"]).to eq("1")
end

test("pending filters by destination state, channel, retry time, and limit") do |pg_connection:, clean_event_deliveries:, fixed_clock:|
  outbox = pg_outbox(pg_connection)
  now = fixed_clock.now.utc
  with_channel = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
  without_channel = outbox.enqueue(EventLogTestSupport.build_envelope)
  outbox.mark_failed(with_channel["id"], "clickhouse",
                     error: "boom", next_retry_at: now + 3600)

  expect(outbox.pending("clickhouse", limit: 10, now:).map { |r| r["id"] })
    .to eq([without_channel["id"]])
  expect(outbox.pending("clickhouse", limit: 10, now: now + 7200).map { |r| r["id"] })
    .to eq([with_channel["id"], without_channel["id"]].sort)
  expect(outbox.pending("teams", limit: 10, now:).map { |r| r["id"] }).to eq([with_channel["id"]])
  expect(outbox.pending("teams", limit: 0, now:)).to eq([])
end

test("marks are independent per destination") do |pg_connection:, clean_event_deliveries:, fixed_clock:|
  outbox = pg_outbox(pg_connection)
  now = fixed_clock.now.utc
  record = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")

  outbox.mark_delivered(record["id"], "clickhouse", at: now)
  outbox.mark_failed(record["id"], "teams", error: "timeout", next_retry_at: now + 60)

  found = outbox.find_by_event_id(record["event_id"])
  expect(found["clickhouse"]["delivered_at"].to_i).to eq(now.to_i)
  expect(found["teams"]["attempts"]).to eq(1)
  expect(found["teams"]["last_error"]).to eq("timeout")
  expect(outbox.pending("clickhouse", limit: 10, now:)).to eq([])
  expect(outbox.pending("teams", limit: 10, now:)).to eq([])
  expect(outbox.pending("teams", limit: 10, now: now + 61).size).to eq(1)
end

test("mark_skipped is terminal and prune keeps pending rows") do |pg_connection:, clean_event_deliveries:, fixed_clock:|
  outbox = pg_outbox(pg_connection)
  now = fixed_clock.now.utc
  skipped = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
  outbox.mark_delivered(skipped["id"], "clickhouse", at: now)
  outbox.mark_skipped(skipped["id"], "teams", reason: "disabled", at: now)
  pending = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
  outbox.mark_delivered(pending["id"], "clickhouse", at: now)

  pg_connection.exec_params(
    "UPDATE event_deliveries SET created_at = $1 WHERE id = $2",
    [(now - 30 * 86_400).iso8601, skipped["id"]]
  )
  pg_connection.exec_params(
    "UPDATE event_deliveries SET created_at = $1 WHERE id = $2",
    [(now - 30 * 86_400).iso8601, pending["id"]]
  )

  expect(outbox.pending("teams", limit: 10, now:).map { |r| r["id"] }).to eq([pending["id"]])
  expect(outbox.prune(before: now - 7 * 86_400)).to eq(1)
  expect(outbox.find_by_event_id(skipped["event_id"])).to be_nil
  expect(outbox.find_by_event_id(pending["event_id"])["id"]).to eq(pending["id"])
end

test("unknown destinations and ids raise") do |pg_connection:, clean_event_deliveries:, fixed_clock:|
  outbox = pg_outbox(pg_connection)

  expect(-> { outbox.pending("pigeon", limit: 1, now: fixed_clock.now) })
    .to raise_error(ArgumentError)
  expect(-> { outbox.mark_delivered(999_999, "clickhouse", at: fixed_clock.now) })
    .to raise_error(ArgumentError)
  expect(outbox.find_by_event_id("00000000-0000-4000-8000-000000000000")).to be_nil
end

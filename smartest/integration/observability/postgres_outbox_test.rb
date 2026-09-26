# frozen_string_literal: true

require "integration/observability_helper"
require "aiconshell/observability/postgres_outbox"

PostgresOutbox = Aiconshell::Observability::PostgresOutbox
PG_OUTBOX_NOW = Time.utc(2026, 9, 26, 12, 0, 0)

def pg_outbox(db)
  # Same connection as the db fixture's transaction, so writes roll back.
  PostgresOutbox.new(db.raw_connection)
end

test("enqueue stores the envelope and is idempotent by event_id") do |db:|
  outbox = pg_outbox(db)
  envelope = EventLogTestSupport.build_envelope

  first = outbox.enqueue(envelope, teams_channel: "ops")
  second = outbox.enqueue(envelope, teams_channel: "other")

  expect(first["event_id"]).to eq(envelope["event_id"])
  expect(second["id"]).to eq(first["id"])
  expect(second["envelope"]["message"]).to eq(envelope["message"])
  expect(second["teams_channel"]).to eq("ops")
  expect(db.raw_connection.exec("SELECT count(*) FROM event_deliveries")[0]["count"].to_i).to eq(1)
end

test("pending filters by destination state, channel, retry time, and limit") do |db:|
  outbox = pg_outbox(db)
  now = PG_OUTBOX_NOW
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

test("marks are independent per destination") do |db:|
  outbox = pg_outbox(db)
  now = PG_OUTBOX_NOW
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

test("mark_skipped is terminal and prune keeps pending rows") do |db:|
  outbox = pg_outbox(db)
  now = PG_OUTBOX_NOW
  skipped = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
  outbox.mark_delivered(skipped["id"], "clickhouse", at: now)
  outbox.mark_skipped(skipped["id"], "teams", reason: "disabled", at: now)
  ch_skipped = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
  outbox.mark_skipped(ch_skipped["id"], "clickhouse", reason: "gave up", at: now)
  outbox.mark_delivered(ch_skipped["id"], "teams", at: now)
  pending = outbox.enqueue(EventLogTestSupport.build_envelope, teams_channel: "ops")
  outbox.mark_delivered(pending["id"], "clickhouse", at: now)

  [skipped["id"], ch_skipped["id"], pending["id"]].each do |id|
    db.raw_connection.exec_params(
      "UPDATE event_deliveries SET created_at = $1 WHERE id = $2",
      [(now - 30 * 86_400).iso8601, id]
    )
  end

  expect(outbox.pending("teams", limit: 10, now:).map { |r| r["id"] }).to eq([pending["id"]])
  expect(outbox.pending("clickhouse", limit: 10, now:)).to eq([])
  expect(outbox.prune(before: now - 7 * 86_400)).to eq(2)
  expect(outbox.find_by_event_id(skipped["event_id"])).to be_nil
  expect(outbox.find_by_event_id(ch_skipped["event_id"])).to be_nil
  expect(outbox.find_by_event_id(pending["event_id"])["id"]).to eq(pending["id"])
end

test("unknown destinations and ids raise") do |db:|
  outbox = pg_outbox(db)

  expect(-> { outbox.pending("pigeon", limit: 1, now: PG_OUTBOX_NOW) })
    .to raise_error(ArgumentError)
  expect(-> { outbox.mark_delivered(999_999, "clickhouse", at: PG_OUTBOX_NOW) })
    .to raise_error(ArgumentError)
  expect(outbox.find_by_event_id("00000000-0000-4000-8000-000000000000")).to be_nil
end

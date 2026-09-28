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

  first = outbox.enqueue(envelope)
  second = outbox.enqueue(envelope)

  expect(first["event_id"]).to eq(envelope["event_id"])
  expect(second["id"]).to eq(first["id"])
  expect(second["envelope"]["message"]).to eq(envelope["message"])
  expect(db.raw_connection.exec("SELECT count(*) FROM event_deliveries")[0]["count"].to_i).to eq(1)
end

test("pending filters by retry time and limit") do |db:|
  outbox = pg_outbox(db)
  now = PG_OUTBOX_NOW
  waiting = outbox.enqueue(EventLogTestSupport.build_envelope)
  ready = outbox.enqueue(EventLogTestSupport.build_envelope)
  outbox.mark_failed(waiting["id"], "clickhouse",
                     error: "boom", next_retry_at: now + 3600)

  expect(outbox.pending("clickhouse", limit: 10, now:).map { |r| r["id"] })
    .to eq([ready["id"]])
  expect(outbox.pending("clickhouse", limit: 10, now: now + 7200).map { |r| r["id"] })
    .to eq([waiting["id"], ready["id"]].sort)
  expect(outbox.pending("clickhouse", limit: 0, now:)).to eq([])
end

test("marks update the clickhouse state") do |db:|
  outbox = pg_outbox(db)
  now = PG_OUTBOX_NOW
  record = outbox.enqueue(EventLogTestSupport.build_envelope)

  outbox.mark_failed(record["id"], "clickhouse", error: "timeout", next_retry_at: now + 60)

  found = outbox.find_by_event_id(record["event_id"])
  expect(found["clickhouse"]["attempts"]).to eq(1)
  expect(found["clickhouse"]["last_error"]).to eq("timeout")
  expect(outbox.pending("clickhouse", limit: 10, now:)).to eq([])
  expect(outbox.pending("clickhouse", limit: 10, now: now + 61).size).to eq(1)

  outbox.mark_delivered(record["id"], "clickhouse", at: now + 61)
  expect(outbox.pending("clickhouse", limit: 10, now: now + 3600)).to eq([])
end

test("mark_skipped is terminal and prune keeps pending rows") do |db:|
  outbox = pg_outbox(db)
  now = PG_OUTBOX_NOW
  delivered = outbox.enqueue(EventLogTestSupport.build_envelope)
  outbox.mark_delivered(delivered["id"], "clickhouse", at: now)
  ch_skipped = outbox.enqueue(EventLogTestSupport.build_envelope)
  outbox.mark_skipped(ch_skipped["id"], "clickhouse", reason: "gave up", at: now)
  pending = outbox.enqueue(EventLogTestSupport.build_envelope)

  [delivered["id"], ch_skipped["id"], pending["id"]].each do |id|
    db.raw_connection.exec_params(
      "UPDATE event_deliveries SET created_at = $1 WHERE id = $2",
      [(now - 30 * 86_400).iso8601, id]
    )
  end

  expect(outbox.pending("clickhouse", limit: 10, now:).map { |r| r["id"] }).to eq([pending["id"]])
  expect(outbox.prune(before: now - 7 * 86_400)).to eq(2)
  expect(outbox.find_by_event_id(delivered["event_id"])).to be_nil
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

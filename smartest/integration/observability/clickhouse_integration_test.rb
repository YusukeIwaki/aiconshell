# frozen_string_literal: true

require "integration/observability_helper"

CH_TEST_BASE_TIME = Time.now.utc - 86_400

def seed_events(adapter)
  first = EventLogTestSupport.build_envelope(
    layer: "coordination", kind: "task.prioritized", message: "Priority updated for batch",
    task_id: 101, correlation_id: "corr-search", data: { "priority" => 10 },
    occurred_at: CH_TEST_BASE_TIME.iso8601(3)
  )
  second = EventLogTestSupport.build_envelope(
    layer: "execution", kind: "run.finished", message: "タスクの優先度を更新しました",
    task_id: 102, correlation_id: "corr-search", data: {},
    occurred_at: (CH_TEST_BASE_TIME + 3600).iso8601(3)
  )
  third = EventLogTestSupport.build_envelope(
    layer: "interaction", kind: "message.received", message: "Hello from Teams",
    task_id: nil, correlation_id: nil, data: { "channel" => "general" },
    occurred_at: (CH_TEST_BASE_TIME + 7200).iso8601(3)
  )
  adapter.insert([first, second, third])
  [first, second, third]
end

test("shipped init SQL applies and round-trips envelopes newest-first") do |ch_event_log:|
  first, _second, third = seed_events(ch_event_log)

  rows = ch_event_log.search(limit: 10)

  expect(rows.size).to eq(3)
  expect(rows.map { |row| row["event_id"] }).to eq([third["event_id"], rows[1]["event_id"], first["event_id"]])
  expect(rows.first["message"]).to eq("Hello from Teams")
  expect(rows.first["data"]).to eq({ "channel" => "general" })
  expect(rows.first["task_id"]).to be_nil
  expect(ch_event_log.exists?(third["event_id"])).to eq(true)
  expect(ch_event_log.exists?("00000000-0000-4000-8000-000000000000")).to eq(false)
end

test("filters by layer, kind, task, correlation, and time range") do |ch_event_log:|
  first, second, _third = seed_events(ch_event_log)

  expect(ch_event_log.search(layer: "execution").map { |r| r["event_id"] }).to eq([second["event_id"]])
  expect(ch_event_log.search(kind: "task.prioritized").map { |r| r["event_id"] }).to eq([first["event_id"]])
  expect(ch_event_log.search(task_id: 101).map { |r| r["event_id"] }).to eq([first["event_id"]])
  expect(ch_event_log.search(correlation_id: "corr-search").size).to eq(2)
  expect(ch_event_log.search(event_id: second["event_id"]).map { |r| r["event_id"] })
    .to eq([second["event_id"]])
  expect(ch_event_log.search(since: (CH_TEST_BASE_TIME + 5400).iso8601(3)).size).to eq(1)
  expect(ch_event_log.search(since: CH_TEST_BASE_TIME - 3600,
                             until_time: CH_TEST_BASE_TIME + 5400).size).to eq(2)
end

test("finds Japanese substrings in message text") do |ch_event_log:|
  _first, second, _third = seed_events(ch_event_log)

  expect(ch_event_log.search(query: "優先度").map { |r| r["event_id"] }).to eq([second["event_id"]])
  expect(ch_event_log.search(query: "Priority").map { |r| r["event_id"] }.size).to eq(1)
  expect(ch_event_log.search(query: "no such text anywhere")).to eq([])
end

test("duplicate inserts collapse to one logical event (FINAL dedupe)") do |ch_event_log:|
  envelope = EventLogTestSupport.build_envelope

  ch_event_log.insert([envelope])
  ch_event_log.insert([envelope])

  rows = ch_event_log.search(event_id: envelope["event_id"])
  expect(rows.size).to eq(1)
  expect(rows.first["message"]).to eq(envelope["message"])
end

test("injection strings are literals, limits clamp") do |ch_event_log:|
  seed_events(ch_event_log)

  expect(ch_event_log.search(query: "' OR '1'='1")).to eq([])
  expect(ch_event_log.search(kind: "task.prioritized' OR '1'='1")).to eq([])
  expect(ch_event_log.search(limit: 5000).size).to eq(3)
  expect(ch_event_log.search(limit: 1).size).to eq(1)
end

test("LIKE wildcards and backslashes match literally") do |ch_event_log:|
  percent = EventLogTestSupport.build_envelope(message: "disk at 100% capacity")
  underscore = EventLogTestSupport.build_envelope(message: "rate under_score applied")
  backslash = EventLogTestSupport.build_envelope(message: "path C:\\logs\\app checked")
  ch_event_log.insert([percent, underscore, backslash])

  expect(ch_event_log.search(query: "100%").map { |r| r["event_id"] }).to eq([percent["event_id"]])
  expect(ch_event_log.search(query: "under_score").map { |r| r["event_id"] }).to eq([underscore["event_id"]])
  expect(ch_event_log.search(query: "C:\\logs\\app").map { |r| r["event_id"] }).to eq([backslash["event_id"]])
  # A bare % must not degenerate into match-everything.
  expect(ch_event_log.search(query: "%").map { |r| r["event_id"] }).to eq([percent["event_id"]])
end

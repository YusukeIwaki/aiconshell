# frozen_string_literal: true

require "event_log_helper"

ClickHouseAdapter = Aiconshell::Observability::ClickHouseAdapter
FakeTransport = EventLogTestSupport::FakeClickHouseTransport
FakeResponse = EventLogTestSupport::FakeResponse

def build_adapter(transport, table: "event_log")
  ClickHouseAdapter.new(
    base_url: "http://clickhouse:8123", database: "aiconshell",
    table:, username: "u", password: "p", transport:
  )
end

test("insert sends one JSONEachRow batch") do
  transport = FakeTransport.new
  adapter = build_adapter(transport)
  envelopes = [
    EventLogTestSupport.build_envelope,
    EventLogTestSupport.build_envelope(message: "second")
  ]

  expect(adapter.insert(envelopes)).to eq(2)

  request = transport.requests.first
  expect(request[:method]).to eq(:post)
  insert_params = URI.decode_www_form(request[:uri].query).to_h
  expect(insert_params["query"]).to match(/INSERT INTO `event_log` FORMAT JSONEachRow/)
  lines = request[:body].split("\n")
  expect(lines.size).to eq(2)
  row = JSON.parse(lines.first)
  expect(row["event_id"]).to eq(envelopes.first["event_id"])
  expect(JSON.parse(row["data_json"])).to eq(envelopes.first["data"])
end

test("insert is a no-op for empty input and rejects bad rows") do
  transport = FakeTransport.new
  adapter = build_adapter(transport)

  expect(adapter.insert([])).to eq(0)
  expect(transport.requests).to eq([])
  expect(-> { adapter.insert([{ "event_id" => nil }]) }).to raise_error(ArgumentError)
end

test("search parameterizes every user value (injection-safe)") do
  body = JSON.generate({ "data" => [], "rows" => 0 })
  transport = FakeTransport.new([FakeResponse.new(200, body)])
  adapter = build_adapter(transport)

  adapter.search(query: "' OR '1'='1", layer: "coordination", kind: "a.b",
                 task_id: 5, correlation_id: "c'1", event_id: "e'1",
                 since: "2026-09-01T00:00:00Z", until_time: "2026-09-30T00:00:00Z",
                 limit: 5)

  request = transport.requests.first
  sql = request[:body]
  expect(sql).not_to match(/' OR '1'/)
  expect(sql).to match(/\{flt_q:String\}/)
  expect(sql).to match(/FINAL/)
  params = URI.decode_www_form(request[:uri].query).to_h
  expect(params["param_flt_q"]).to eq("' OR '1'='1")
  expect(params["param_flt_corr"]).to eq("c'1")
  expect(params["database"]).to eq("aiconshell")
end

test("search validates layer, times, and table names") do
  transport = FakeTransport.new([FakeResponse.new(200, JSON.generate({ "data" => [] }))])
  adapter = build_adapter(transport)

  expect(-> { adapter.search(layer: "nope") }).to raise_error(ArgumentError)
  expect(-> { adapter.search(since: "whenever") }).to raise_error(ArgumentError)
  expect(-> { adapter.search(limit: "many") }).to raise_error(ArgumentError)
  expect(-> { build_adapter(transport, table: "event_log; DROP TABLE x") })
    .to raise_error(ArgumentError)
  expect(transport.requests).to eq([])
end

test("search clamps limits and normalizes rows") do
  row = { "event_id" => "e1", "layer" => "execution", "kind" => "run.finished",
          "message" => "ok", "data_json" => "{\"a\":1}", "task_id" => 9,
          "correlation_id" => nil, "occurred_at" => "2026-09-26 12:00:00.000", "version" => 1 }
  transport = FakeTransport.new([FakeResponse.new(200, JSON.generate({ "data" => [row] }))])
  adapter = build_adapter(transport)

  results = adapter.search(limit: 5000)

  expect(results.size).to eq(1)
  expect(results.first["data"]).to eq({ "a" => 1 })
  expect(transport.requests.first[:body]).to match(/LIMIT 1000/)
end

test("transport and server failures raise sanitized ClickHouseError") do
  transport = FakeTransport.new([StandardError.new("boom token=zzz")])
  adapter = build_adapter(transport)

  begin
    adapter.search(query: "x")
    raise "expected ClickHouseError"
  rescue Aiconshell::Observability::ClickHouseError => e
    expect(e.message).not_to match(/zzz/)
  end

  bad = FakeTransport.new([FakeResponse.new(500, "Code: 60. DB::Exception: boom")])
  expect(-> { build_adapter(bad).insert([EventLogTestSupport.build_envelope]) })
    .to raise_error(Aiconshell::Observability::ClickHouseError)
end

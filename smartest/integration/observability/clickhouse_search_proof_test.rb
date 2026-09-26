# frozen_string_literal: true

require "integration/observability_helper"

# Proves the LIKE substring strategy against a realistically sized table:
# 9000+ rows (two 8192-row granules) with one rare English and one rare
# Japanese message. EXPLAIN indexes=1 must show granule narrowing through
# the skip indexes for both, and search must recall both rows.
PROOF_TABLE = "event_log_explain_proof"
PROOF_FILLER_ROWS = 9000
PROOF_RARE_EN = "ZebraQuixoticRareTokenXyZ123"
PROOF_RARE_JA = "稀有検索用特別トークンぷにょXyZ"

def build_proof_table!(real_clickhouse:)
  cfg = EventLogTestSupport::ClickHouseConfig
  cfg.execute!("DROP TABLE IF EXISTS #{PROOF_TABLE}")
  ddl = File.read(File.join(REPO_ROOT, "db/clickhouse/001_create_event_log.sql"))
  cfg.execute!(ddl.gsub("event_log", PROOF_TABLE))

  # Padded to ~1.2 KB per row (within the 4000-char envelope cap): with
  # tiny rows ClickHouse adaptive granularity would merge all 9000 into a
  # single granule and the narrowing proof would be vacuous.
  pad = "x" * 1100
  rows = Array.new(PROOF_FILLER_ROWS) do |i|
    { "event_id" => SecureRandom.uuid, "layer" => "coordination", "kind" => "bulk.noise",
      "message" => "routine heartbeat log entry number #{i} #{pad}",
      "occurred_at" => "2026-09-01 00:00:00.000", "data" => {},
      "task_id" => nil, "correlation_id" => nil, "version" => 1 }
  end
  en_id = SecureRandom.uuid
  ja_id = SecureRandom.uuid
  rows << { "event_id" => en_id, "layer" => "coordination", "kind" => "task.prioritized",
            "message" => "special event holding #{PROOF_RARE_EN} marker",
            "occurred_at" => "2026-09-02 00:00:00.000", "data" => {},
            "task_id" => 1, "correlation_id" => "corr-rare", "version" => 1 }
  rows << { "event_id" => ja_id, "layer" => "execution", "kind" => "run.finished",
            "message" => "特別な日本語イベント #{PROOF_RARE_JA} を含む",
            "occurred_at" => "2026-09-02 01:00:00.000", "data" => {},
            "task_id" => 2, "correlation_id" => "corr-rare-ja", "version" => 1 }
  proof_adapter(real_clickhouse).insert(rows)
  cfg.execute!("OPTIMIZE TABLE #{PROOF_TABLE} FINAL")
  [en_id, ja_id]
end

def proof_adapter(real_clickhouse)
  Aiconshell::Observability::ClickHouseAdapter.new(
    base_url: real_clickhouse.base_url, database: real_clickhouse.database,
    table: PROOF_TABLE, username: EventLogTestSupport::ClickHouseConfig.username,
    password: EventLogTestSupport::ClickHouseConfig.password,
    open_timeout: 5, read_timeout: 60
  )
end

# Captures the exact SQL + params the adapter emits, then EXPLAINs them
# against the real server.
def explain_adapter_search(query_text)
  fake = EventLogTestSupport::FakeClickHouseTransport.new(
    [EventLogTestSupport::FakeResponse.new(200, JSON.generate({ "data" => [], "rows" => 0 }))]
  )
  capturing = Aiconshell::Observability::ClickHouseAdapter.new(
    base_url: "http://localhost:8123", database: "unused", table: PROOF_TABLE, transport: fake
  )
  capturing.search(query: query_text)
  captured = fake.requests.first
  params = URI.decode_www_form(captured[:uri].query).to_h.reject { |key, _| key == "database" }
  # Drop the trailing FORMAT JSON so EXPLAIN renders as plain text.
  sql = captured[:body].sub(/\s*FORMAT JSON\s*\z/, "")
  EventLogTestSupport::ClickHouseConfig.execute_with_params!(
    "EXPLAIN indexes = 1 #{sql}", params
  )
end

test("EXPLAIN shows skip-index narrowing for rare English and Japanese") do |real_clickhouse:|
  en_id, ja_id = build_proof_table!(real_clickhouse:)
  begin
    [PROOF_RARE_EN, PROOF_RARE_JA].each do |rare|
      plan = explain_adapter_search(rare)
      # Non-vacuous: the table spans 2 granules, the skip index reads 1.
      unless plan.match?(/Granules: 2\/2/) &&
             plan.match?(/Name: idx_message_ngram[\s\S]{0,400}Granules: 1\//)
        raise "expected 2-granule table with 1-granule narrowing for #{rare.inspect}:\n#{plan}"
      end
    end

    adapter = proof_adapter(real_clickhouse)
    expect(adapter.search(query: PROOF_RARE_EN).map { |r| r["event_id"] }).to eq([en_id])
    expect(adapter.search(query: PROOF_RARE_JA).map { |r| r["event_id"] }).to eq([ja_id])
  ensure
    EventLogTestSupport::ClickHouseConfig.execute!("DROP TABLE IF EXISTS #{PROOF_TABLE}")
  end
end

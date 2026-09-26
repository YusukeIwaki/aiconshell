-- aiconshell EventLog ClickHouse schema (ClickHouse 26.8).
--
-- Apply with a database selected, e.g.:
--   clickhouse-client --database aiconshell < db/clickhouse/001_create_event_log.sql
-- or over HTTP:
--   curl -u "$CLICKHOUSE_USER:$CLICKHOUSE_PASSWORD" -X POST \
--     "$CLICKHOUSE_URL/?database=aiconshell" --data-binary @db/clickhouse/001_create_event_log.sql
--
-- The statement is idempotent (IF NOT EXISTS) and safe to re-run. Column or
-- index changes require a new ALTER migration file, not an edit here.
--
-- Design notes:
-- * ReplacingMergeTree(ingested_at) collapses redeliveries of the same
--   event_id; background merges dedupe eventually, while reads must use
--   FINAL (or GROUP BY event_id) for exact results.
-- * ORDER BY starts with event_id so point lookups and dedupe stay cheap.
-- * PARTITION BY month keeps TTL drops and range scans partition-local.
-- * TTL 180 days: the EventLog is operational history, not a compliance
--   archive. Adjust per operations policy with an ALTER ... MODIFY TTL.
-- * Substring search is message LIKE %...% (literal, escaped). On 26.8
--   LIKE is what idx_message_text (ASCII) and idx_message_ngram
--   accelerate, including Japanese, which has no whitespace tokens.
--   position()/match() predicates use no skipping and are not used.
-- * Writes use JSONEachRow over HTTP; reads use parameterized {name:Type}
--   placeholders (see lib/aiconshell/observability/clickhouse_adapter.rb).

CREATE TABLE IF NOT EXISTS event_log
(
    event_id String,
    layer LowCardinality(String),
    kind LowCardinality(String),
    message String,
    data_json String CODEC(ZSTD(1)),
    task_id Nullable(Int64),
    correlation_id Nullable(String),
    occurred_at DateTime64(3, 'UTC'),
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    version UInt8 DEFAULT 1,
    INDEX idx_message_text message TYPE text(tokenizer = 'splitByNonAlpha') GRANULARITY 1,
    INDEX idx_message_ngram message TYPE ngrambf_v1(3, 1024, 3, 0) GRANULARITY 1,
    INDEX idx_correlation correlation_id TYPE bloom_filter GRANULARITY 1
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (event_id, occurred_at)
TTL occurred_at + INTERVAL 180 DAY
SETTINGS index_granularity = 8192;

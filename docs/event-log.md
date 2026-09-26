# EventLog (ClickHouse + outbox + Teams)

Each layer emits structured events. `emit` writes a redacted, validated
envelope to the PostgreSQL outbox spool and returns; a recurring job drains
the spool into ClickHouse (searchable history) and, for opted-in events, a
Teams channel. Logging failures never roll back business updates.

```ruby
Aiconshell::Observability.emit(
  layer: "coordination", kind: "task.prioritized", message: "Priority updated",
  task_id: 123, correlation_id: "uuid", data: { priority: 10 }
)
Aiconshell::Observability.search(query: "優先度", layer: "coordination", limit: 50)
```

Rails call sites use the thin wrappers `EventLogging::Emitter` /
`EventLogging::Search`, which delegate to the port above.

## Envelope contract

Required: `event_id` (UUID, default generated), `layer`
(`interaction`/`coordination`/`execution`), `kind`
(`[a-z0-9][a-z0-9_.:-]{0,127}`), `message` (1–4000 chars, truncated with a
marker), `occurred_at` (ISO8601, default now), `data` (object),
`version` (`1`). Optional: `task_id` (integer), `correlation_id` (≤128
chars). `emit!` raises `ValidationError` on violations; `emit` logs a
sanitized warning and returns `nil`.

Size caps: any single `data` string is truncated to 2000 chars, `data` JSON
to 32 KiB, and the whole envelope to 64 KiB. Oversized envelopes are
dropped (never truncated silently at the envelope level) so a giant payload
cannot evict or corrupt neighbors.

## Redaction

Applied before validation, so only redacted bytes are stored, searched, or
posted to Teams:

- Keys: password/passwd, secret, token, authorization, credential,
  cookie, session, bearer, `*_key` patterns (`api_key`, `access_key`,
  `private_key`, `client_secret`), `database_url`, plus exact carrier keys
  that must never be logged (`prompt`, `system_prompt`, `user_prompt`,
  `cli_output`, `raw_cli_output`, `raw_output`, `command_output`, `stdout`,
  `stderr`). Matching is case-insensitive over key segments; innocent keys
  such as `author` or `idempotency_key` are preserved.
- Strings: email addresses → `[redacted-email]`; `Bearer`/`Basic`
  credentials → `[REDACTED]`; `password=`/`token=`-style fragments inside
  URLs and query strings → `[REDACTED]`.
- Errors recorded in `*_last_error` or logs are single-line, truncated to
  500 chars, and redacted; backtraces are never stored (they can embed
  arguments and environment).

Callers must still avoid passing AI prompts or raw provider output: the
carrier-key list is a backstop, not permission.

## Outbox spool (PostgreSQL)

Table `event_deliveries` (migration `db/migrate/20260926000005_*`): the
envelope plus `teams_channel` and independent per-destination state
(`*_delivered_at`, `*_skipped_at`, `*_attempts`, `*_next_retry_at`,
`*_last_error`) for `clickhouse` and `teams`. `event_id` is unique, so
double-enqueue (e.g. business-transaction retry) stores one row.

Delivery (`Aiconshell::Observability::DeliveryService`, run by
`EventLogDeliveryJob` on the `control` queue):

- ClickHouse rows are claimed in batches and inserted with one JSONEachRow
  request; the delivered mark is written only after the insert succeeds.
- Teams rows are posted one message per row through the plugins port
  (`teams` / `send_message`); when the sink is disabled the rows are marked
  skipped, not retried.
- Failures back off exponentially (2 min × 2^(attempts−1), capped at 6 h)
  per destination. ClickHouse success followed by Teams failure never
  re-inserts into ClickHouse.
- Delivered rows are pruned after 7 days (`prune_retention_days:`). The
  spool is not an archive: history lives in ClickHouse.

Run one delivery job at a time (Solid Queue concurrency limit); concurrent
runs are safe for ClickHouse (idempotent by `event_id`) but can double-post
Teams on crash replays (see below).

## ClickHouse

Init SQL: `db/clickhouse/001_create_event_log.sql` (idempotent; verified
against ClickHouse 26.8.11.7):

- `ReplacingMergeTree(ingested_at)`, `ORDER BY (event_id, occurred_at)`,
  monthly partitions, TTL 180 days, ZSTD on `data_json`.
- `ngrambf` index for substring search (`position`/`LIKE`), which covers
  Japanese text that has no whitespace tokens; `text` index for ASCII token
  queries (`hasToken`); bloom filter on `correlation_id`.
- Reads always use `FINAL` (exact dedupe) with `ORDER BY occurred_at DESC`
  and a clamped `LIMIT` (default 100, max 1000). Writes are HTTP
  `JSONEachRow` batches with 5 s connect / 15 s read timeouts.
- All user input travels as `{name:Type}` parameters over the HTTP
  interface; table names are allow-list validated and limits are clamped
  integers. No user text is interpolated into SQL.

Minimum resources: a single ClickHouse node is sufficient for this
workload; start with the vendor's small single-node sizing (2 vCPU / 4 GiB
class) and watch `system.merges` and query latency before scaling. No
sharding or replicas in the initial topology; add replicas only when
measured availability needs them.

## Teams delivery

`TeamsSink` calls `registry.invoke(plugin: "teams", operation:
"send_message", input: {"scope", "body"})` with a ≤1000-char
`[layer/kind] message (task #id)` body. It is disabled when no registry is
injected or the Teams plugin catalog entry reports unconfigured. The sink
logs through its injected logger only and never emits events, so a Teams
outage cannot recurse into the outbox.

## Duplication guarantees

- ClickHouse: at-least-once delivery, exactly-once reads. Replays collapse
  by `event_id` (background merges eventually; `FINAL` reads exactly).
  `search(event_id:)` re-reads one logical event idempotently.
- Teams: at-least-once with no provider idempotency. Success followed by a
  crash before the delivered mark double-posts; concurrent delivery runs
  can do the same. Keep one scheduler and treat Teams as notification, not
  record.
- Outbox: `event_id` unique; `enqueue` is idempotent.

## Failure behavior and loss conditions

- `emit` performs no network I/O and rescues everything: worst case the
  event is dropped and a sanitized warning names layer/kind. `emit` inside
  a rolled-back transaction loses the row with it (outbox write shares the
  transaction); emit after commit for must-keep audit events.
- Outbox (PostgreSQL) down: `emit` drops with a warning; delivery runs
  fail loudly in logs and retry on the next tick. Events emitted during the
  outage are lost — the documented trade-off for "logging never breaks
  business updates".
- ClickHouse down: rows stay pending with backoff; nothing is dropped and
  Teams delivery continues independently.
- ClickHouse unconfigured (`CLICKHOUSE_URL` unset): rows stay pending and
  each run logs an error. This is a deploy misconfiguration — alert on it,
  do not let the spool grow silently.
- Teams disabled/failing: rows are skipped (disabled) or retried with
  backoff (failing); ClickHouse delivery is unaffected.
- Delivery-job crash between sink success and delivered mark: redelivery
  (see duplication guarantees). The job itself never emits events, so
  delivery failures cannot loop back into the spool.

## Operations

Environment: `CLICKHOUSE_URL` (e.g. `http://clickhouse:8123`),
`CLICKHOUSE_DATABASE` (default `aiconshell`), `CLICKHOUSE_TABLE` (default
`event_log`), `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`. Credentials travel
in the HTTP Authorization header and never appear in logs or error pages.

Recurring schedule (foundation `config/recurring.yml`, control queue):

```yaml
event_log_delivery:
  class: EventLogDeliveryJob
  queue: control
  schedule: every minute
```

Monitor: outbox pending counts and max `*_attempts` (alert on growth),
delivery-job errors, ClickHouse `system.merges` lag, and spool table size
(prune keeps it to ~7 days of delivered rows). To re-apply schema, re-run
the init SQL (idempotent); column changes ship as new `ALTER` files.

Rails wiring note: `lib/aiconshell` is required explicitly (`require
"aiconshell/observability"`), not via Zeitwerk autoload, so the same files
load standalone in scripts and tests. If the foundation enables
`config.autoload_lib`, exclude `lib/aiconshell` from autoloading (or remove
the explicit requires) — mixing both double-defines constants.

## Why ClickHouse over MongoDB for this log

The workload is append-only time-series text with filters on time, layer,
kind, task, and correlation, plus substring search over message text,
column compression, batch ingest, and time-based expiry. ClickHouse fits
that shape directly: columnar storage with per-column codecs, monthly
partitions with TTL drops, `ReplacingMergeTree` idempotent replays, and
`ngrambf`/`text` secondary indexes for substring and token search.

MongoDB fits document-at-a-time updates and flexible per-document shape,
with B-tree and `$text` indexes; the EventLog has no per-document updates
(only idempotent replays) and filters narrow time/attribute slices, so the
document model's strengths are unused here while TTL and compression need
more manual tuning.

No claim is made here about absolute speed or cost: with no measurements,
"faster" or "cheaper" would be unfounded. Open verification items are small
data-foundation costs (single-node baseline memory), Japanese substring
recall at scale, and TTL-drop behavior under real retention windows; the
acceptance run covers functional insert/search on 26.8 only.

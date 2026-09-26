# Verification (issue #9, bounded acceptance slice — part 2)

Branch: `codex/issue-9-acceptance`. This file records only what was actually
observed in this worktree. Anything not listed here was not verified here.

Part 2 supersedes the part-1 note about a fake event sink: this lane merged
`codex/issue-7-admin` (merge `5483e69`, tip `db8eaee`: reviewed EventLog
boot wiring, corrected migrations `20260927000001`/`20260927000601..603`,
complete `db/schema.rb`, admin/wiring test isolation) as a root-authorized
dependency merge. No pull request was created, nothing was pushed to main,
and no issue was closed from this session.

## Scope of this bounded part

New/owned files in this lane only:

- `smartest/integration/acceptance/acceptance_helper.rb`
- `smartest/integration/acceptance/end_to_end_test.rb`
- `docs/verification.md` (this file)

No product code was changed. Issue-3 (GitHub cursor/pagination) files were
not merged and not touched; the acceptance stubs still target the old
adapter endpoints (exact surface documented below) and will need a final
adjustment after root integrates issue-3.

## What the acceptance test proves

`smartest/integration/acceptance/end_to_end_test.rb` runs one human GitHub
issue through the real stack on the exclusive PostgreSQL database
`aiconshell_issue_9_integrated_test`:

poll (real `Github` adapter) -> inbox ingest -> structured coordination
triage/dispatch (real `Ai::Runner`) -> leased execution in a dedicated
workspace consuming the immutable dispatch snapshot -> coordinator
completion -> persisted outbound -> interaction draft + schema-validated
external reply (real registry both ways).

Real under test: `Aiconshell::Plugins::Registry` + `Github` adapter,
`Aiconshell::Ai::Runner` + `ProcessRunner` (real subprocess spawn, one
process per layer call), `Interaction` / `Coordination` / `Execution`
services, all shared tables including `SolidQueue::Job`, and the real
`WorkflowEvents` -> `Aiconshell::Observability` -> `EventLogging::
OutboxAdapter` boot wiring from `config/initializers/event_log.rb`.

The event sink is no longer a fake: `RecordingEventSink` forwards every
emit to the real `WorkflowEvents` facade and keeps the real return values.
The test then proves persistence rather than mirroring:

- every forwarded emit returned a non-nil envelope (a dropped emit returns
  nil and would fail here);
- every forwarded `event_id` is present as an `EventDelivery` row, and
  `EventDelivery.count` equals the forwarded count (no drops, no extras);
- the persisted rows cover all three layers and the seven expected
  lifecycle kinds (`poll.completed`, `triage.ingested`, `triage.completed`,
  `dispatch.created`, `run.leased`, `run.completed`, `outbound.sent`), with
  no `*.failed` / `triage.ai_failed` rows;
- each row's envelope matches its identity columns (`event_id`, `layer`,
  `kind`) and carries `occurred_at`.

Leak check on the real path: a random `ACCEPTANCE_CANARY_SECRET` is planted
in ENV and inside the untrusted issue title, so it travels through
`ExternalEvent` payloads, Task title/description, `TaskFeedback`, and AI
prompt stdin (asserted present in stdin, making the absence below
meaningful). Every persisted envelope is then scanned and contains neither
the canary, nor the fetched installation token, nor prompt markers, nor raw
CLI stdout fragments (`"structured_output"`, `"subtype":"success"`).

Faked at the boundary only:

- HTTP transport is scripted (fake installation token, issues, comments,
  runs, comment creation). No network, no real GitHub posting.
- The `claude` executable is a temporary generated script answering the
  three layer prompts with schema-valid `structured_output`. No
  subscription login, no model call, no host auth read (child auth home
  points at a temp dir; the child environment is asserted to exclude
  `TEST_DATABASE_URL`, `DATABASE_URL`, `GITHUB_*`, and the planted canary).

This test is therefore NOT real AI-account verification. It proves
wiring, schemas, leases, snapshots, workspaces, EventLog persistence, and
secret handling; it says nothing about model answer quality or real
provider/CLIs.

## Exact scripted HTTP surface (old adapter)

All served in-process by `ScriptedTransport`; no request leaves the test
process. Shapes match the pre-issue-3 `Github` adapter:

1. `POST https://api.github.com/app/installations/789/access_tokens` ->
   `{"token": "fake-installation-token", "expires_at": "2030-01-01T00:00:00Z"}`.
   The test asserts the exchange happened (POST) and that listing requests
   actually carried `Authorization: Bearer fake-installation-token`.
2. `GET https://api.github.com/repos/o/r/issues?<query>` (Regexp
   `%r{/repos/o/r/issues\?}`) -> first call one issue
   (`number 1`, `updated_at 2026-09-26T12:01:00Z`), later calls the same
   issue with `updated_at 2026-09-26T12:10:00Z`. Title carries the canary:
   `"Login fails on retry (ref <canary>)"`.
3. `GET .../repos/o/r/issues/1/comments...` (Regexp) -> first call comment
   101 (`"clarification: only affects Safari"`), later calls 101 plus 102
   (`"still broken after deploy"`).
4. `GET .../repos/o/r/actions/runs...` (Regexp) ->
   `{"workflow_runs": []}`.
5. `POST .../repos/o/r/issues/1/comments` (Regexp) ->
   `{"id": 555, "html_url": "https://github.com/o/r/issues/1#c555"}`.
   Exactly one POST is asserted: a duplicate post would be a real bug.

Deliberately NOT asserted: exact per-poll GET counts for listing
endpoints. Pagination can legitimately add requests, so the test asserts
each resource family was listed at least once, the second poll re-listed,
auth was used, and the reply POST happened exactly once with
schema-valid input.

## Commands run and observed output

Exclusive database (created 2026-09-27; `psql` is not installed on this
host, so creation used the `pg` gem):

```sh
RBENV_VERSION=3.4.9 rbenv exec ruby -r pg -e \
  'PG.connect("postgresql://postgres:aiconshell_dev@127.0.0.1:55432/postgres") \
   .exec("CREATE DATABASE aiconshell_issue_9_integrated_test")'
# observed: created, no error
```

`db:prepare` is valid after the merge (corrected migrations + complete
schema). `db/schema.rb` untouched (`git status` shows no modification):

```sh
RAILS_ENV=test \
TEST_DATABASE_URL='postgresql://postgres:aiconshell_dev@127.0.0.1:55432/aiconshell_issue_9_integrated_test' \
RBENV_VERSION=3.4.9 rbenv exec bundle exec rails db:prepare
# observed: success, no output; event_deliveries and all workflow/solid_queue tables present
```

Acceptance slice on the exclusive database:

```sh
RAILS_ENV=test TEST_DATABASE_URL='.../aiconshell_issue_9_integrated_test' \
RBENV_VERSION=3.4.9 rbenv exec bundle exec smartest smartest/integration/acceptance
# observed: 1 test, 1 passed, 0 failed
```

Full integration suite against real PostgreSQL + real ClickHouse:

```sh
RAILS_ENV=test \
TEST_DATABASE_URL='postgresql://postgres:aiconshell_dev@127.0.0.1:55432/aiconshell_issue_9_integrated_test' \
TEST_PG_DBNAME='aiconshell_issue_9_integrated_test' \
TEST_CLICKHOUSE_DATABASE='aiconshell_issue_9_integrated_test' \
TEST_CLICKHOUSE_URL='http://127.0.0.1:58123' \
TEST_CLICKHOUSE_USER='aiconshell' \
TEST_CLICKHOUSE_PASSWORD='aiconshell_dev' \
RBENV_VERSION=3.4.9 rbenv exec bundle exec smartest smartest/integration
# observed: 145 tests, 145 passed, 0 failed, 0 skipped, exit 0
# (144 baseline + 1 acceptance; ClickHouse search-proof/FINAL-dedupe and
# cross-process delivery-lock tests all ran unskipped against real services)
```

Disk had room (`/dev/vda1` 76% used, ~13.4G available in
`aiconshell-dev-postgres`); no prune was needed and no Docker resources
were touched.

## Not verified here (explicitly out of scope for this part)

- Real AI accounts / real subscription CLIs / model answer quality.
- `smartest/unit` and the plugin/AI suites (checked separately by root).
- Docker Compose build/up, web+worker shared-DB check, admin manual
  browsing, Railway deploy, GitHub CI, provider login flows.

No Railway deployment, no GitHub CI result, no Compose acceptance, and no
real provider login is claimed: none was observed.

## Product/integration findings for root

1. Old Github adapter drops human text from event payloads
   (`lib/aiconshell/plugins/github.rb`, not this lane's file, not changed):
   issue events keep `title` but no `body`; comment events keep only
   `owner/repo/number/comment_id/url`. Consequence observed in this slice:
   `TaskFeedback` rows built from comments contain metadata JSON instead of
   the human's words, and the only untrusted text reaching AI prompts is
   the issue title. The canary carrier was chosen accordingly (issue
   title). Suggested follow-up for the issue-3 lane: confirm whether the
   new cursor/pagination adapter preserves bodies; the acceptance stubs
   need a final pass after that integration regardless.
2. No other defects found. The only failure seen during development was a
   wrong assumption in the new acceptance test itself (canary first placed
   in a comment body, which this adapter version never forwards); fixed in
   the owned test files. No product change was needed and none is
   proposed. No temporary debug output remains in the committed files (a
   throwaway Smartest failure-line probe was used from `/tmp` only).

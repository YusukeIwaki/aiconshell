# Verification (issue #9, bounded part 1 — draft)

Branch: `codex/issue-9-acceptance`. This file records only what was actually
observed in this worktree. Anything not listed here was not verified here.

## Scope of this bounded part

New files owned by this lane only:

- `smartest/integration/acceptance/acceptance_helper.rb`
- `smartest/integration/acceptance/end_to_end_test.rb`
- `docs/verification.md` (this file)

No product code was changed. Plugin/EventLog corrections and the deployment
lane are being finalized elsewhere; their files were not touched.

## What the acceptance test proves

`smartest/integration/acceptance/end_to_end_test.rb` runs one human GitHub
issue through the real stack on real PostgreSQL (tables + Solid Queue
tables on the exclusive database `aiconshell_issue_9_test`):

poll (real `Github` adapter) -> inbox ingest -> structured coordination
triage/dispatch (real `Ai::Runner`) -> leased execution in a dedicated
workspace consuming the immutable dispatch snapshot -> coordinator
completion -> persisted outbound -> interaction draft + schema-validated
external reply (real registry both ways).

Real under test: `Aiconshell::Plugins::Registry` + `Github` adapter,
`Aiconshell::Ai::Runner` + `ProcessRunner` (real subprocess spawn, one
process per layer call), `Interaction` / `Coordination` / `Execution`
services, all shared tables including `SolidQueue::Job`.

Faked at the boundary only:

- HTTP transport is scripted (fake installation token, issues, comments,
  runs, comment creation). No network, no real GitHub posting.
- The `claude` executable is a temporary generated script answering the
  three layer prompts with schema-valid `structured_output`. No
  subscription login, no model call, no host auth read (child auth home
  points at a temp dir; the child environment is asserted to exclude
  `TEST_DATABASE_URL`, `DATABASE_URL`, `GITHUB_*`, and a planted canary).
- The event sink is a capturing fake: final EventLog boot wiring is still
  pending in another lane.

This test is therefore NOT real AI-account verification. It proves
wiring, schemas, leases, snapshots, workspaces, and secret handling; it
says nothing about model answer quality or real provider/CLIs.

## Commands run and observed output

Exclusive database (created 2026-09-27; `psql` is not installed on this
host, so creation used the `pg` gem):

```sh
RBENV_VERSION=3.4.9 rbenv exec ruby -r pg -e \
  'PG.connect("postgresql://postgres:aiconshell_dev@127.0.0.1:55432/postgres") \
   .exec("CREATE DATABASE aiconshell_issue_9_test")'
# observed: created
```

Migrate (schema dump redirected per lane instructions; the worktree
`db/schema.rb` is untouched — `git status` shows no modification there):

```sh
RAILS_ENV=test \
TEST_DATABASE_URL='postgresql://postgres:aiconshell_dev@127.0.0.1:55432/aiconshell_issue_9_test' \
SCHEMA=/tmp/aiconshell-delivery-20260926/acceptance-schema.rb \
RBENV_VERSION=3.4.9 rbenv exec ruby bin/rails db:migrate
# observed: all migrations applied, including 20260927000001..3
```

Suites (each on the exclusive database above):

```sh
RAILS_ENV=test TEST_DATABASE_URL='...' RBENV_VERSION=3.4.9 \
  rbenv exec bundle exec smartest smartest/integration/acceptance
# observed: 1 test, 1 passed, 0 failed

RAILS_ENV=test TEST_DATABASE_URL='...' RBENV_VERSION=3.4.9 \
  rbenv exec bundle exec smartest smartest/integration/workflow
# observed: 51 tests, 51 passed, 0 failed

RAILS_ENV=test TEST_DATABASE_URL='...' RBENV_VERSION=3.4.9 \
  rbenv exec bundle exec smartest smartest/integration/admin
# observed: 45 tests, 45 passed, 0 failed
```

## Environment note (shared Docker VM disk full)

`CREATE DATABASE` first failed with `PG::DiskFull`: the shared Docker VM
disk was at 100% (`docker exec aiconshell-dev-postgres df` showed
`/dev/vda1 ... 100%`). Remediation was build-cache-only, no lane data
touched (no images, containers, or volumes removed):

```sh
docker builder prune -f --filter 'until=168h'
# observed: Total: 1.466GB reclaimed; VM disk then had ~1.3G available
```

The unrelated images filling the disk (playwright/puppeteer trees from
other projects) were left alone. Other lanes sharing
`aiconshell-dev-postgres` were blocked by the same condition.

## Not verified here (explicitly out of scope for this part)

- Real AI accounts / real subscription CLIs / model answer quality.
- Full test matrix (`smartest/unit`, remaining `smartest/integration`
  trees, plugin/ai/observability suites) and `bin/rails zeitwerk:check`
  (no Rails wiring was changed in this lane).
- Docker Compose build/up, web+worker shared-DB check, ClickHouse real
  insert/search (the lane's ClickHouse server was not used), admin
  manual browsing, Railway deploy, GitHub CI.
- Final EventLog wiring (fake sink used, see above).

No Railway deployment, no GitHub CI result, and no final Compose
acceptance is claimed: none was observed.

## Product defects found

None. The only failures seen during development were mistakes in the new
acceptance fixtures themselves (stub timing, macOS tmpdir symlink
canonicalization, `ARGV` vs `$PROGRAM_NAME` in the fake CLI evidence,
wire-body vs registry-input schema framing); each was fixed in the owned
test files. No product change was needed and none is proposed.

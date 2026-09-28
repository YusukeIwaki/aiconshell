---
name: aiconshell-testing
description: Write and run aiconshell tests (テスト) — Smartest suites, boundary fixtures, isolated PostgreSQL/ClickHouse, Zeitwerk — and report results honestly. Use when adding regression tests, choosing which suite to run, setting up a test DB for a worktree, or verifying a change before handoff or review.
---

# aiconshell testing

Run from the repository root. `docs/testing.md` is the source of truth for commands,
fixtures and assertions; this skill is the checklist.

## Writing tests

1. Put tests under `smartest/**/*_test.rb` in the suite that matches the dependency:
   unit/plugins/ai need no DB or network; integration uses real PostgreSQL.
2. Replace only the external boundary (`BoundaryFixtures::HttpTransport`,
   `ScriptedProcessRunner`/`with_ai`). Keep domain services, Registry, schema validation real.
   Every new test asserts `assert_consumed!` for its HTTP and AI scripts.
3. Assert durable state and forbidden side effects (no Task/TaskRun, no external write,
   no unsafe EventLog content), not only response text. UI assertions target the specific
   form, row or notice element. Do not pin prompt wording unless it is a safety contract.
4. Reproduce the Issue's failure condition first when fixing a bug; the test should fail before the fix.

## Running tests

1. Use Ruby 3.4.9 through Bundler: `RBENV_VERSION=3.4.9 rbenv exec bundle exec ./bin/test unit|integration|all`.
2. For integration, start dedicated containers tagged with the Issue as in `docs/testing.md`
   ("worktree用の一時DB"), with free ports and explicit `TEST_*` variables. Never reuse
   another lane's DB, production settings, or other containers' environment. Stop only the
   containers you started.
3. Run `bin/rails zeitwerk:check` when Rails wiring (autoload paths, constants, initializers) changes.
4. When piping output, use `set -o pipefail`, and read Smartest's failure and skip counts.
   Do not call a partial run (PG only, targeted directory) a full verification.

## Reporting

List each command actually run with pass/fail/skip counts; state what was not run and why.
Do not weaken assertions, substitute SQLite, enable live providers, or call a skipped check successful.

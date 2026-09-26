# Aiconshell

AI engineer foundation: Rails 8 + PostgreSQL + Solid Queue on Ruby 3.4.9.
See `docs/architecture.md` for boundaries and `AGENTS.md` for working agreements.

Issue #2 scope is the runnable foundation only: web boot, one shared
PostgreSQL database (Solid Queue tables included, no separate queue DB),
health check, plain ERB/CSS landing page, and the Smartest test setup.
No domain models and no `/admin` yet (later issues).

## Requirements

- Ruby 3.4.9 (`rbenv`; see `.ruby-version`, pinned in `Gemfile`)
- PostgreSQL 16+ reachable over TCP
- No Node/JS toolchain (plain Propshaft CSS + ERB, no JS build)

## Setup

```sh
cp .env.example .env   # then set DATABASE_URL / TEST_DATABASE_URL
bin/setup --skip-server
```

`bin/setup` installs the locked bundle and runs `db:prepare` for both
development and test databases. Without `--skip-server` it execs `bin/dev`
(Puma on http://localhost:3000).

Environment:

| Variable | Used by | Default |
| --- | --- | --- |
| `DATABASE_URL` | development, production | `postgresql://localhost/aiconshell_development` (dev only; production requires it) |
| `TEST_DATABASE_URL` | test | `DATABASE_URL`, else `postgresql://localhost/aiconshell_test` |
| `SECRET_KEY_BASE` | production | (required in production; no credentials file is used) |
| `RAILS_MAX_THREADS` | Puma + DB pool | `5` (`3` for Puma threads) |
| `JOB_CONCURRENCY` | `bin/jobs` worker processes | `1` |

Never commit `.env` (see `.gitignore`). Production refuses to boot without
an explicit `DATABASE_URL`.

## Running

```sh
bin/dev    # web (Puma, port 3000)
bin/jobs   # Solid Queue supervisor: dispatcher + workers on the same DB
```

Health: `GET /up` (200 when the app boots). Landing page: `GET /`.

Worker modes (`bin/jobs --help`): default `fork` mode is for Linux Docker,
the primary supported worker runtime (issue #8 owns the operations image
and the full worker smoke). On macOS, forked workers are unreliable
(pg native extension + ObjC runtime fork safety, outside issue #2 scope),
so local macOS development must use `bin/jobs --mode=async`
(thread supervisor, no `fork()`).

## Tests (Smartest)

```sh
bin/test              # unit + integration
bin/test unit         # smartest/unit: no Rails boot, no DB, no network
bin/test integration  # smartest/integration: real PostgreSQL via TEST_DATABASE_URL
```

- Unit tests require `test_helper` only and must stay Rails/DB/network free.
- Integration tests require `db_helper`, which boots `RAILS_ENV=test`,
  refuses non-`*_test` databases, and rolls back a per-test transaction
  on teardown (see `smartest/db_fixtures/rails_fixture.rb`).
- Raw runner: `bundle exec smartest smartest/unit` (same for integration).
- Lanes add suites under `smartest/unit/<area>/` or
  `smartest/integration/<area>/`; directory args expand recursively so new
  files are discovered automatically. Full multi-suite discovery/CI wiring
  is owned by issues #8/#9.

Also run `bin/rails zeitwerk:check` after Rails wiring changes.

## Layout

- `app/` — stock Rails 8 (Puma, CSRF/CSP defaults); only `HomeController`
  is app-specific so far. `ApplicationJob`/`ApplicationRecord` are empty
  base classes, not domain models.
- `config/queue.yml`, `config/recurring.yml`, `bin/jobs` — Solid Queue.
- `db/migrate/*_create_solid_queue_tables.rb` — queue tables in the
  shared database ([single-DB setup](https://github.com/rails/solid_queue#single-database-configuration)).
- `lib/aiconshell/{plugins,ai,observability}/` — owned by later lanes;
  explicitly required, never autoloaded (see `lib/aiconshell/README.md`).
- `smartest/` — `test_helper.rb` (unit), `db_helper.rb` (integration),
  `fixtures/`, `db_fixtures/`, `matchers/`, `unit/`, `integration/`.

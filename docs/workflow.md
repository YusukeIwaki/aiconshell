# Workflow: Interaction / Coordination / Execution (issue #6)

The executable vertical slice: humans can never instruct a worker directly.
Every layer boundary below is enforced in Ruby and covered by Smartest tests
(`smartest/unit/workflow`, `smartest/integration/workflow`).

```
human event -> Interaction poll -> ExternalEvent (durable inbox)
  -> Coordination triage (coordination AI) -> Task inbox/ready
  -> Coordination dispatch -> TaskRun pending + ExecutionRunJob (:execution)
  -> Execution lease + bounded AI -> CompletionService (coordination)
  -> Task done/waiting_* (+ OutboundAction) -> Interaction delivery
```

## Models

| Model | Owner writes | Notes |
| --- | --- | --- |
| `ExternalEvent` | Interaction | `plugin+event_id+fingerprint` unique; edits land as new rows |
| `IntegrationCursor` | Interaction | per plugin/scope cursor + short poll lease + visible error |
| `Task` | Coordination only | `inbox/ready/running/waiting_human/waiting_review/done/failed/cancelled`, `lock_version` |
| `TaskFeedback` | anyone creates, Coordination consumes | `body/author/suggested_priority`, never mutates Task directly |
| `TaskRun` | Coordination creates, Execution leases | provider snapshot, `lease_token` fencing, result/error |
| `LayerPolicy` | admin UI | one row per layer, `enabled` flag, no secrets |
| `OutboundAction` | Coordination creates, Interaction sends | idempotency key, attempts, external id |

Task transitions are a closed allowlist (`Task::TRANSITIONS`); unknown
transitions raise `ActiveRecord::RecordInvalid` and AI rulings requesting
them are rejected per ruling, never applied partially.

## Layer rules

- **Interaction** (`app/services/interaction/`): polls allowlisted scopes
  into the inbox, delivers outbound actions. Polling validates scopes
  against `AICONSHELL_ALLOWED_SCOPES`, never trusts caller/AI destinations
  alone. Bot/system events are persisted pre-processed so self-events start
  no loops. When the interaction `LayerPolicy` is enabled, reply bodies are
  drafted through that policy before sending; otherwise the
  coordination-provided body is sent as-is. An enabled policy naming an
  unconfigured provider fails the action structurally (`error_code`), with
  no silent fallback.
- **Coordination** (`app/services/coordination/`): the only layer that
  creates tasks, changes `status`/`priority`/`next_action_at`, persists
  runs, and decides dispatch/completion. Triage ingests deterministically
  (new source -> inbox Task; known source -> TaskFeedback on the open
  task), then calls the coordination AI with a strict ruling schema.
  Unknown task ids, operations, and transitions are rejected. Without an
  enabled policy, ingest still runs but tasks stay in `inbox`; the
  deterministic priority fallback runs in explicit demo mode
  (`AICONSHELL_DEMO_MODE=1`) only.
- **Execution** (`app/services/execution/`): leases one persisted run,
  runs the bounded AI call in an isolated workspace, returns the
  structured result to `Coordination::CompletionService`. It never updates
  `Task` rows and never calls plugins (static boundary test). Workers
  receive normalized task data only.

Controllers (admin lane) accept `TaskFeedback` and configure
`LayerPolicy`; they never enqueue or invoke `ExecutionRunJob`. Only
`Coordination::DispatchService` / `RecoveryService` enqueue it.

## Durability and fencing guarantees

- Cursor commits only after **all** valid events of a poll are persisted.
  Invalid rows are skipped visibly (`last_error`, `poll.failed`) and the
  cursor is held so the poll is retryable; valid rows are idempotent on
  retry via the unique fingerprint constraint.
- Overlapping polls are skipped via a short cursor lease (row lock +
  token + expiry), checked and set without holding locks across network I/O.
- Completions are fenced by `lease_token`: wrong token, expired-lease
  reuse, or terminal-run replay is rejected (`stale_completion`) and can
  never overwrite newer state. All state mutations use row locks
  (`with_lock`) and short transactions; AI subprocess/network calls always
  run outside the lock.
- Lease discipline: `AICONSHELL_LEASE_SECONDS` (default 1800) must exceed
  `AICONSHELL_AI_TIMEOUT_SECONDS` (default 600) so a healthy run never
  loses its lease mid-call; `RunnerService#heartbeat` extends the lease
  when operators configure a tighter window. Boot logs a warning when the
  lease does not cover the AI timeout.
- Expired leases recover on the control queue: the stale run parks as
  `expired` and a fresh `pending` run dispatches while attempts remain,
  else the task parks as `failed` with a visible error. No `running` ->
  `ready` transition exists, so recovery never invents one.
- Every layer AI policy is optional at boot. Saving a policy that names
  an unconfigured provider is valid; execution records a structured
  failure (`provider_not_configured`, `run.failed`) instead of raising
  through the job. Missing/denied configuration never raises for endless
  Solid Queue retries: jobs retry transient errors only (bounded
  `retry_on`), config errors are recorded and back off (`next_action_at`).
- Test fakes (`smartest/fixtures/workflow_fakes.rb`) are injected
  explicitly in tests only. Production defaults resolve the real
  `Aiconshell::Plugins::Registry` / `Aiconshell::Ai::Runner` when present
  and record an explicit unavailable-error otherwise.

## Outbound exactly-once caveat

`idempotency_key` de-duplicates enqueue/claim retries inside the app, but
GitHub/Jira/Teams writes have no end-to-end idempotency: a crash after a
successful plugin call and before the `sent` update can resend on the
next delivery pass. Treat outbound delivery as at-least-once and keep
messages idempotent-worded where it matters.

## Operator setup

Environment (see `config/initializers/aiconshell_workflow.rb`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `AICONSHELL_EXECUTION_ROOT` | `tmp/ai_workspaces` | workspaces live under `task_<id>/run_<id>` here; required in production, never an arbitrary human/AI path |
| `AICONSHELL_ALLOWED_SCOPES` | empty (deny all) | comma `plugin:scope` allowlist, e.g. `github:owner/repo,github:issue-1` |
| `AICONSHELL_LEASE_SECONDS` | `1800` | execution lease; keep above the AI timeout |
| `AICONSHELL_AI_TIMEOUT_SECONDS` | `600` | bounded AI runtime per call |
| `AICONSHELL_POLL_LEASE_SECONDS` | `300` | overlap guard per poll |
| `AICONSHELL_MAX_RUN_ATTEMPTS` | `3` | lease-recovery redispatch cap |
| `AICONSHELL_MAX_ACTION_ATTEMPTS` | `5` | outbound claim cap |
| `AICONSHELL_DEMO_MODE` | unset | `1` enables the deterministic triage fallback only |

Recurring jobs (control queue unless noted; wire into
`config/recurring.yml` when the foundation/operations lanes land):

```yaml
interaction_poll:
  class: InteractionPollJob
  queue: control
  args: ["github", "owner/repo"]   # one entry per allowlisted scope
  schedule: every 5 minutes
coordination_triage:
  class: CoordinationTriageJob
  queue: control
  schedule: every 5 minutes
lease_recovery:
  class: LeaseRecoveryJob
  queue: control
  schedule: every 10 minutes
```

`ExecutionRunJob` runs on the `execution` queue; give execution workers
their own Solid Queue process with access to the execution root and AI
CLI auth, and no application DB/integration credentials beyond the
database connection. AI subprocesses inherit a controlled env only (see
the AI lane), never provider stdout/stderr into EventLog.

## Public contract notes for other lanes

- Ports used exactly as documented in `docs/architecture.md`:
  `registry.invoke(plugin:, operation:, input:, context:)`,
  `runner.call(provider:, prompt:, schema:, workspace:, layer:, ...)`,
  `Observability.emit(layer:, kind:, message:, ...)`. No changes required.
- Admin lane: build feedback/policy controllers on `TaskFeedback` and
  `LayerPolicy`; do not add run-creation endpoints (covered by the
  boundary test).
- Queue config: split `control` and `execution` workers in
  `config/queue.yml` (operations lane); jobs already declare their queue.

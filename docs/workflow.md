# Workflow: Interaction / Coordination / Execution (issue #6)

Human messages and external events are data. Coordination alone decides task
state, priority, execution requests, and outbound intent. Controllers create
human `TaskFeedback` or configure `LayerPolicy`; they do not invoke a worker.

```
plugin polling -> ExternalEvent -> coordination triage -> Task + TaskRun
  -> execution lease + bounded AI -> coordination completion
  -> OutboundAction -> interaction delivery
```

## Persisted contracts

- `ExternalEvent` is unique on plugin/event ID/fingerprint. Edits are distinct
  rows. Ingestion records its `task_id`; one open task per nonempty source is
  enforced by PostgreSQL. Source creation uses a transaction advisory lock,
  then a locked task lookup. A new event after a completed source creates a
  new inbox task.
- `TaskFeedback` accepts human authors only, at both model and database levels.
  System events remain source context and never impersonate human feedback.
  Missing text is normalized from descriptions, change items, or structured
  payloads. Invalid inbox rows are quarantined with a safe `last_error` and
  `processed_at`, so they cannot starve later events.
- `TaskRun` stores provider/model/effort/instructions and `work_snapshot` at
  dispatch. Those fields are read-only thereafter. The snapshot contains the
  task description, work plan, human clarification, recent source events,
  and previous structured result. Recovery copies the original request.
- PostgreSQL permits only one pending/leased/running run per task.
  `Task.current_run_id` identifies the request authorized to affect its state.
  Duplicate dispatch returns the same current active run.
- Task transitions use `Task::TRANSITIONS`. A `running` request must dispatch
  execution; triage cannot manufacture a running task without a run. Changing
  a running task to another state cancels its active run and clears the pointer.
  Terminal tasks with pending human feedback remain triageable. Coordination
  may explicitly reopen them to `inbox` only with that feedback and when no
  other open task owns the source. Reopening does not revive old runs.

## Triage and feedback

Triage first ingests events and then calls the enabled coordination policy.
There is no production priority fallback. Explicit demo mode can advance inbox
items to ready using suggested priorities.

Each AI call receives a task version and exact feedback snapshot, including
previous execution results. Rulings are JSON Schema validated, then checked
against task identity, the current policy, task version, allowed transitions,
and trusted reply destination. Duplicate rulings are rejected. A stale ruling
cannot overwrite a completion that happened during the AI call.

Only a successfully applied ruling acknowledges its snapshotted feedback IDs,
in the same transaction. Feedback for rejected or omitted tasks, and feedback
arriving during the AI call, remains pending. Descriptions, work plans, and
clarifications are persisted with the execution request so a resumed worker can
use the human answer. Replies can only target the task's existing source; AI
text cannot select a different plugin or resource.

## Execution and recovery

All paths lock the task before its run. Worker claims require a pending current
run, a running task, and an enabled execution policy. A missing or disabled
execution policy never selects another provider. Queued work is deferred while
the policy is disabled and the maintenance sweep can resume it after enabling.
An enabled but unconfigured provider remains selectable and fails visibly at
execution with a structured error.

Completion and heartbeat require the current task/run association, a nonempty
matching lease token, an active run, and an unexpired lease. Stale, expired,
cancelled, or duplicate results cannot change the task. Only `done`,
`waiting_review`, `waiting_human`, and `failed` are accepted outcomes. Invalid
output is a failed run; the worker reports a rejected completion instead of
claiming success. Raw provider diagnostics are not copied into task errors.

Expired current runs become `expired` and receive a fresh request while attempts
remain and execution is enabled. Superseded/cancelled runs are never recovered.
Exhausted or disabled recovery parks the task as failed with a visible reason.

The lease must exceed the bounded AI timeout by more than ten seconds for
process shutdown. Configuration is validated at boot and before dispatch or
execution. Safety does not require heartbeat callbacks from a blocking adapter.
Workspaces use canonical paths beneath the configured execution root and reject
symlinked child directories before writing through them. Production requires an
explicit root. Provider subprocess environment isolation belongs to the AI port;
execution never invokes external plugins.

## Polling and outbound delivery

Polling claims a short cursor lease. Network paging happens outside a database
transaction; the current token is checked under the cursor lock before events
and the cursor are committed atomically. Duplicate fingerprint inserts are
idempotent. Invalid output or a stale lease cannot advance the cursor.

`github.issue`, `jira.issue`, `teams.message`, and `teams.reply` are semantic
snapshots. Their adapter fingerprint is preserved as `source_fingerprint`;
the inbox `fingerprint` chains it to the preceding persisted revision. Thus
observed A → B → A changes create three revisions, while consecutive A
snapshots only advance `source_updated_at`, the greatest provider `occurred_at`
observed for that revision. Metadata timestamps in the payload do not create
new work. Other event types retain their original fingerprint deduplication.

Per-plugin/event-ID transaction advisory locks serialize snapshot writes across
scopes, acquired in sorted order. A batch is processed in timestamp order for
each source. Snapshots older than the persisted watermark are ignored; equal
timestamps are first-observed-wins (batch input order breaks ties). Providers
must supply the edit time as `occurred_at`; timestamps are compared at PostgreSQL
microsecond precision. Conflicting changes at the same timestamp and changes
that occur entirely between polls cannot be reconstructed. Existing rows retain
their old fingerprint as the initial source value; changing an adapter's
fingerprint algorithm can create one new baseline revision. All snapshot,
watermark, and cursor changes commit together, with lease expiry rechecked after
lock waits. No network request runs while these locks are held.

Only known bots/self actors are pre-processed to prevent echo loops; other
system events are retained as coordination context. Set
`AICONSHELL_SELF_ACTOR_IDS=plugin:id,...` (or `JIRA_SERVICE_ACCOUNT_ID` for Jira).
Jira outbound writes fail with `self_actor_not_configured` without a known self
account identity.

Outbound actions have `pending`, `sending`, `sent`, `failed`, and `uncertain`
states, plus lease, request-start, and retry timestamps. Interaction derives a
reply's scope from its resource ID, checks the operator allowlist, and passes
operation permission arrays to the real plugin registry. Enabled interaction
policies may draft the body. Plugin inputs and outputs remain schema validated.

A bounded retry follows a 429 Retry-After response. Transport ambiguity or a
crash after a remote request started becomes `uncertain` and is not automatically
resent. Interrupted local drafting can return to pending after backoff. Remote
providers do not offer an end-to-end exactly-once guarantee; operators must
reconcile uncertain sends before deciding whether another action is needed.

## Admin result batches and delivery reconciliation (issue #11, pass 2)

Cross-connector admin requests persist a validated coordination result
`{summary, actions: [{plugin, operation, input}]}` (`summary` 1–2000 chars,
at most 20 actions). Only tasks with a trusted persisted origin are
eligible: `Task#admin_request?` requires a stored human `ExternalEvent`
with plugin `admin` and event type `admin.task_request` matching the
task's source reference. Source strings or payload flags alone never
authorize, and ordinary external tasks keep their existing reply rules.

`Coordination::ResultService.new(registry:, event_sink:, clock:,
allowed_scopes:).apply(task_id:, task_version:, feedback_ids:, policy:,
result:)` validates every action through
`Interaction::ActionValidator#validate(plugin:, operation:, input:)` —
supported non-read-only writes (`reply`, `create_issue`, `send_message`),
exact registered input schemas, destinations derived with
`PluginAccess` against current `AICONSHELL_ALLOWED_SCOPES` — before any
mutation. The whole batch, `coordination_result` (`summary`,
`action_count`), `delivery_batch_key`, state change, and exact feedback
acknowledgements then commit atomically under the task lock, guarded by
an unchanged task `lock_version` and an enabled/unchanged coordination
policy. Idempotency keys are stable: batch `result-<task_id>-<version>`,
actions `result-<task_id>-<version>-<ordinal>`. Running tasks, current
run pointers, active runs, terminal tasks, `waiting_delivery` tasks, and
any outstanding pending/sending action reject the result. No-action
results complete as `done` with the stored summary; action results move
to `waiting_delivery`, never directly to `done`. No execution is
enqueued and no `TaskRun` is created. The shared `Task::TRANSITIONS` map
is unchanged; the result path uses its own explicit from-state
allowlist. Result codes: `:ok`, `:invalid_result`, `:unknown_task`,
`:duplicate_result`, `:stale_task`, `:stale_policy`,
`:not_admin_origin`, `:task_running`, `:terminal_task`, `:batch_active`,
`:outstanding_actions`, plus validator codes (`:unknown_plugin`,
`:unknown_operation`, `:unsupported_operation`,
`:operation_not_allowed`, `:not_writable`, `:input_invalid`,
`:scope_not_allowed`) with the failing `action_index`.

Only `Coordination::DeliveryReconciler` leaves `waiting_delivery`.
`reconcile(task_id:)` verifies exact batch membership against the
persisted batch key and a positive expected count; missing, deleted, or
mismatched counts recover to `waiting_human` (`batch_mismatch`), never
vacuously succeeding. Batches with any pending/sending action stay
`waiting_delivery`. All-`sent` batches complete as `done`; any
`failed`/`uncertain` delivery parks as `waiting_human` with a
content-free reason (`delivery_failed`, `delivery_uncertain`, or
`delivery_partial`), clears `next_action_at`, and never autonomously
resends or replans. Reconciliation never acknowledges human feedback;
new explicit feedback unlocks later Coordination handling, and prior
batch metadata stays until a new authorized result replaces it.
`WorkflowMaintenanceJob` runs `reconcile_all(limit: 100)` before its
execution-policy early return, so settlement works with execution
disabled. PostgreSQL treats `waiting_delivery` as open in
`index_tasks_one_open_per_source`.

`CompletionService` never creates replies for the internal admin
origin, including execution-dispatched admin tasks. `WorkContext`
additionally exposes the bounded prior `coordination_result`
(summary truncated to 500 chars, `action_count`) and recent delivery
metadata (batch key, plugin, operation, normalized destination, status,
content-free `error_code`) without action bodies, so replanning after a
failed/uncertain batch sees previously attempted writes.

Outbound delivery validates the exact registered plugin input/output
schemas for the action's operation and preserves the full input,
including custom required fields; unknown/unsupported operations and
schema violations fail before any transport or handler call. Schemas
permit only `reply`, `create_issue`, and `send_message`; no other write
operations were added. The admin task board still groups unknown
statuses into its inbox column (controllers/views are a separate
lane); surfacing `coordination_result` there is a follow-up handoff.

Not implemented in this pass (next phase): the Triage typed read loop
that will call `ResultService#apply` under its existing snapshots.
Triage currently still snapshots `waiting_delivery` tasks with pending
feedback, so the next pass must route those to reconciliation (or skip
them) instead of acknowledging feedback without effect, and keep the
legacy `reply` field source-bound alongside the new result path.

## Runtime configuration

Pure Ruby plugin, AI, and observability entrypoints are explicitly required at
boot; Zeitwerk does not manage those namespaces. Missing lane libraries are
reported at startup and produce explicit runtime failures. Test fakes are
injected only in tests. Web, workers, and Solid Queue share PostgreSQL.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AICONSHELL_EXECUTION_ROOT` | `tmp/ai_workspaces` outside production | Canonical root for policy and task/run workspaces; required in production |
| `AICONSHELL_ALLOWED_SCOPES` | empty | Comma-separated plugin destinations, e.g. `github:owner/repo` |
| `AICONSHELL_SELF_ACTOR_IDS` | empty | Known self actors as `plugin:id,...` |
| `JIRA_SERVICE_ACCOUNT_ID` | unset | Jira self actor identity required for outbound writes |
| `AICONSHELL_LEASE_SECONDS` | `1800` | Must exceed AI timeout plus ten seconds |
| `AICONSHELL_AI_TIMEOUT_SECONDS` | `600` | Bounded AI runtime |
| `AICONSHELL_POLL_LEASE_SECONDS` | `300` | Poll cursor lease |
| `AICONSHELL_MAX_RUN_ATTEMPTS` | `3` | Execution recovery attempt cap |
| `AICONSHELL_MAX_ACTION_ATTEMPTS` | `5` | Outbound attempt cap |
| `AICONSHELL_DEMO_MODE` | unset | `1` explicitly enables deterministic inbox triage |

Operations schedules `IntegrationPollScheduleJob` every five minutes; it
enqueues polling for configured plugins and concrete allowlisted scopes.
Empty allowlists disable polling, while unconfigured plugins are checked
again on later ticks. Coordination, recovery, and maintenance use
`CoordinationTriageJob`, `LeaseRecoveryJob`, and `WorkflowMaintenanceJob`.
The maintenance job runs every minute to recover outbound leases and enqueue
due actions and current pending runs, repairing process/enqueue failures.
Control and execution jobs declare separate queues and should use separate
worker processes. AI/network calls never hold a database transaction open.

## Verification

Smartest workflow integration tests use PostgreSQL and injected ports. Core
regressions cover actual concurrent dispatch, database uniqueness, exact feedback
acknowledgements, stale triage and worker completions, cancellation, disabled
policies, clarification snapshots, invalid outcomes, source normalization,
terminal feedback, lease bounds, and symlink containment. Interaction regressions
exercise real plugin registry contracts with fake transports. Runtime provider
login, live AI execution, and real external posting are separate acceptance
checks; these tests do not use accounts or network integrations.

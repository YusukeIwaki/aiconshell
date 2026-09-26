# Admin task requests (issue #10)

Authenticated operators submit natural-language task requests through the admin
UI and a JSON admin API. Both use the shared intake
`Interaction::TaskRequestIntake`, which persists one durable receipt
(`TaskRequest`) plus one `ExternalEvent` in a single transaction. Coordination
ingests the event later; intake controllers never create `Task`/`TaskRun`,
never decide scheduling, and never invoke execution.

Parallel issue #11 owns Task/Coordination/plugin/outbound changes. This lane
adds no Task fields and does not edit Coordination, plugins, outbound
workflow, or `docs/architecture.md`.

## Routes

| Method | Path | Auth | Result |
| --- | --- | --- | --- |
| GET | `/admin/task_requests/new` | UI Basic | HTML form with server UUID key |
| POST | `/admin/task_requests` | UI Basic + CSRF | 302 to receipt, or 422/409 form |
| GET | `/admin/task_requests/:id` | UI Basic | HTML receipt (`:id` is request UUID) |
| POST | `/api/admin/task_requests` | Bearer `ADMIN_API_TOKEN` | 202 JSON receipt |
| GET | `/api/admin/task_requests/:id` | Bearer `ADMIN_API_TOKEN` | 200 JSON receipt |

The board (`/admin/tasks`) links to the new-request form. The UI is Japanese;
API status/error codes stay English machine values (`accepted`, `processed`,
`invalid_payload`, and so on).

## Authentication

- UI reuses `Admin::BaseController` Basic auth (`ADMIN_USERNAME` /
  `ADMIN_PASSWORD`, fail closed when blank) and keeps Rails CSRF protection.
  No CSRF bypass was added.
- API uses a separate `ADMIN_API_TOKEN` environment variable, fail closed
  when blank or missing. Only `Authorization: Bearer <token>` is accepted,
  compared in constant time (SHA256 digests). Basic auth and cookies are
  never accepted as API fallback. The API ancestry is
  `Api::Admin::BaseController < ActionController::API`, so UI protection
  cannot be bypassed through the API.
- Auth runs before body validation: a malformed or oversized body with bad
  credentials still returns 401 `unauthorized`.

## Input validation

JSON Schema (strict):

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["title", "description"],
  "properties": {
    "title": { "type": "string", "minLength": 1, "maxLength": 500 },
    "description": { "type": "string", "minLength": 1, "maxLength": 8000 }
  }
}
```

- `title` and `description` are required nonblank strings (whitespace-only
  is rejected), max 500 and 8000 chars.
- Values are stripped of leading/trailing whitespace before storage and
  before idempotency comparison (same-key retry compares stripped values).
- Strings containing U+0000 are rejected as 422 `invalid_payload` at the
  shared intake boundary, before any persistence. Normal Unicode and
  newlines are preserved.
- Unknown fields are rejected, including any attempted `plugin`, `source`,
  `status`, `priority`, `provider`, `worker`, `commands`, or event metadata.
  UI forms accept only `task_request[title]`, `task_request[description]`
  plus a top-level `idempotency_key` (and required Rails routing/form
  control fields); API bodies accept only `title`/`description`.

## API body guard and byte bound

`ApiTaskRequestBodyGuard` (middleware, issue #10 only) runs ahead of Rails
parameter parsing/logging for `/api/admin/task_requests` and its receipt
routes, including `.:format`, trailing slash and repeated-slash variants.
It accepts at most 128 KiB of actual request body bytes (not `Content-Length`),
reading at most one extra byte to detect overflow. It parses JSON once, stashes the
result for the controller, and replaces `rack.input` with an empty body so
the framework never reparses the original bytes. It never returns a response
itself, so 401 keeps precedence. Receipt GET bodies are ignored and kept out
of parameter logs. Other routes are untouched.

- 128 KiB admits a compact maximum payload (title 500 + description 8000
  Unicode chars) even when every astral char is JSON-escaped as surrogate
  pairs (~102 KiB + framing).
- Bodies over the bound, including excess JSON formatting whitespace, return
  422 `invalid_payload`. Malformed JSON or invalid UTF-8 returns 400 `malformed_json`;
  non-JSON `Content-Type` returns 400 `json_only`.
- Because the guard replaces the body before Rails parses, malformed bytes
  and rejected unknown-field values never reach framework DEBUG logs.

## Idempotency contract

- Namespaces are separate: UI keys live in namespace `ui`, API keys in
  namespace `api`. PostgreSQL enforces uniqueness on
  `(idempotency_namespace, idempotency_key)`, so the same string in UI and
  API never collides.
- UI: `GET new` generates a fresh UUID hidden field (`idempotency_key`,
  top-level). The key is retry-stable: validation failures (422) re-render
  the same key with the submitted values preserved.
- API: `Idempotency-Key` header is required. UI keys must be UUID format;
  API keys must match `[A-Za-z0-9_\-:.]{1,128}` (bounded, 1-128 chars).
  Missing or malformed keys are 422.
- Same key + same (stripped) payload returns the existing receipt (UI: 302
  redirect to the existing receipt; API: 202 with the same `request_id`).
- Same key + different payload is a conflict (UI: 409 form with a
  content-free message; API: 409 `idempotency_conflict`). Reuse with
  different payload never overwrites and never creates a second receipt.
- The hidden/header key is only an idempotency key. It is never trusted as
  event metadata: request, resource, and event identities are always
  server-generated fresh UUIDs.
- Duplicate races are decided by the database unique index inside a
  savepoint (`requires_new`). The loser re-reads the winner and returns
  duplicate or conflict; the caller's outer transaction stays usable and no
  partial receipt/event rows remain.

## Receipt and event identities

- Receipt public id is `request_id`, an opaque UUID (`to_param`). Lookups
  use `TaskRequest.find_by(request_id:)` only. Integer ids and arbitrary
  `ExternalEvent` ids never resolve: UI redirects unknown ids to the
  new-request form, API returns 404 `not_found`.
- `status` is derived: `accepted` while the event is unprocessed,
  `processed` once Coordination marks `processed_at`. `task_id` is
  `external_event.task_id` (nil until ingestion assigns a Task). The UI
  labels these `タスク整理待ち` and `タスク作成済み`.
- Event is server-owned: `plugin: "admin"`,
  `event_type: "admin.task_request"`, `actor_type: "human"`,
  `actor_id: "admin"` (UI) or `"admin-api"` (API). Each accepted request
  gets fresh UUIDs for `event_id` and `resource_id` (its own resource, not
  one shared admin conversation); `fingerprint` equals `event_id`.
  `occurred_at` uses the injected clock.
- Payload is `{ "title": "...", "description": "...",
  "request_id": "<uuid>" }` at full accepted lengths (500/8000).

## Triage

After the outermost transaction commits, intake asks for
`CoordinationTriageJob` (via `after_all_transactions_commit`, so a rolled-back
acceptance enqueues and emits nothing). When that ask fails, intake still
succeeds and the existing recurring triage ingests the event; the failure is
logged and emitted content-free.

Normal `Coordination::TriageService` ingestion assigns the event to a Task
and marks `processed_at`. The full receipt and event payload (500/8000) are
preserved by this lane; Task-row mapping details are owned by parallel issue
#11 and are not asserted here.

## EventLog and log hygiene

- Intake emits content-free `interaction/task_request.accepted` with data
  `{ "request_id": "<uuid>" }` on new acceptance only (duplicates do not
  re-emit). Enqueue failure emits
  `interaction/task_request.triage_ask_failed` with the same shape.
- No `title`/`description`/body, idempotency secret, or token appears in
  logs, errors, or EventLog data. Rails `filter_parameters` includes
  `:title`, `:description`, and `:body`; `:idempotency_key` is covered by
  the existing `:_key` partial match. `Authorization` is never logged.

## API examples

```sh
curl -i -X POST http://127.0.0.1:3000/api/admin/task_requests \
  -H "Authorization: Bearer $ADMIN_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000" \
  -d '{"title":"Fix login","description":"Steps to reproduce..."}'
# 202 + Location: /api/admin/task_requests/<request_id>
# {"request_id":"<uuid>","status":"accepted","task_id":null}

curl -s http://127.0.0.1:3000/api/admin/task_requests/<uuid> \
  -H "Authorization: Bearer $ADMIN_API_TOKEN"
# 200 {"request_id":"<uuid>","status":"accepted","task_id":null}
```

API errors (all content-free JSON):

- 202 accepted/duplicate, 200 receipt read, 409 `idempotency_conflict`,
  422 `invalid_payload` (including oversized bodies over 128 KiB and
  U+0000 strings) or `invalid_idempotency_key`,
  400 `malformed_json` or `json_only` (non-JSON Content-Type),
  401 `unauthorized`, 404 `not_found`.

## Files

- `db/migrate/20260927010000_create_task_requests.rb`,
  `app/models/task_request.rb`,
  `app/services/interaction/task_request_intake.rb`
- `app/controllers/admin/task_requests_controller.rb`,
  `app/views/admin/task_requests/{new,show}.html.erb`,
  board link in `app/views/admin/tasks/index.html.erb`
- `app/controllers/api/admin/{base_controller,task_requests_controller}.rb`,
  `app/middleware/api_task_request_body_guard.rb`,
  `config/routes/api.rb`, `draw(:api)` in `config/routes.rb`
- `config/initializers/filter_parameter_logging.rb`
  (`:title`, `:description`, `:body`)
- `smartest/integration/admin/support/task_request_test_support.rb`
- `.env.example`, `compose.yml` (web `ADMIN_API_TOKEN`), `README.md`,
  `docs/deployment.md` (Railway `ADMIN_API_TOKEN`)

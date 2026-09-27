# AI auth protocol (worker-side subscription login)

Worker-only Ruby port that starts official CLI subscription logins and reads
their status, so the admin UI can connect Claude / Codex / Muse Code accounts
without the web tier ever handling CLIs or long-lived tokens. Normal AI
inference and task execution stay independent of this operations surface.

Ownership (issue #16): `lib/aiconshell/ai/authentication.rb` and its
subdirectory, the `require` line in `lib/aiconshell/ai.rb`,
`smartest/ai/authentication_*`, and this document. Rails models,
controllers, jobs, views and queue configuration belong to another issue.

All challenge URLs, query values and user codes in fixtures and in this
document are placeholders (`PLACEHOLDER`, `TEST-…`, `DEMO…`): only the
official host/path shapes are real. Real transcripts must never be recorded.

## Contract

```ruby
runner = Aiconshell::Ai::Authentication::Runner.new(
  config: Aiconshell::Ai::Config.default, # registry:, process_runner:,
  session_factory:, clock: also injectable
)
runner.status(provider: "codex")
# => {"state" => "connected", "error_code" => nil}
runner.login(provider: "muse", timeout: 900,
             on_challenge: ->(challenge) { ... },
             input: -> { ... }, cancelled: -> { false })
```

Both methods always return a schema-validated string-key Hash and never raise
for operational failures: unknown providers, bad inputs, spawn errors,
unexpected CLI output and callback failures map to fixed classifications.
Raw stdout/stderr, tokens, secret file contents and exception text never
leave the boundary.

States: `connected`, `disconnected`, `unavailable` (CLI executable missing),
`failed`. `login` additionally returns `cancelled` (cancel callback fired)
and `expired` (deadline passed, or the CLI reported an expired code).
`error_code` is null unless state is `failed`:

| `error_code` | Meaning |
| --- | --- |
| `invalid_provider` | provider is not `claude`, `codex` or `muse` |
| `invalid_argument` | bad timeout or non-callable callback |
| `spawn_failed` | auth dir or child process could not start |
| `timeout` | status probe exceeded its internal deadline |
| `unexpected_output` | unparseable or unrecognized CLI output |
| `output_capped` | output exceeded `max_output_bytes` |
| `challenge_rejected` | verification URL failed the provider policy |
| `auth_rejected` | CLI reports auth failure, or an API-key/access-token lane was detected |
| `callback_failed` | `on_challenge` raised |
| `input_failed` | `input` raised or returned a malformed code |
| `cancel_check_failed` | `cancelled` raised |
| `interrupted` | child I/O failed mid-session (broken pipe, …) |
| `unknown` | last-resort guard; carries no detail |

`on_challenge` receives only schema-validated challenges (emitted on first
sight and on material change — code arrival, prompt appearance):

```json
{"verification_uri": "https://…", "user_code": "string or null", "input_required": false}
```

The URI keeps its query (the flow needs it) and must match the provider's
official HTTPS host/path exactly; userinfo, non-443 ports, control
characters, fragments and unlisted hosts/paths are rejected and fail the
attempt with `challenge_rejected`. `user_code` is transient guidance and may
be null.

`input.call` is consulted for Claude only, after the `Paste code here if
prompted` stdin prompt appears: nil while empty, the authorization code
String once. The code is written to the child stdin pipe (never argv) and
stdin is then closed. `cancelled.call` is polled about every 0.2s with the
deadline; cancel, timeout, callback failure and child exit all terminate the
child process group and close FDs in finite time.

## Provider commands

Children run with an argv array (no shell), the `ChildEnv` allowlist env (no
DB/integration/API-key variables) and the provider auth dir on the private
volume as dedicated cwd. No arbitrary commands, no generic terminal, no
custom OAuth client.

| Provider | Login | Status |
| --- | --- | --- |
| Claude Code | `claude auth login --claudeai` (subscription; never `--console`) | `claude auth status --json` → `{"loggedIn": bool, …}` |
| Codex | `codex login --device-auth -c forced_login_method="chatgpt" -c cli_auth_credentials_store="file"` (never `--with-api-key` / `--with-access-token`) | `codex login status` with the same `-c` overrides → human text |
| Muse Code | `muse login` (browser code approval, polled) | no CLI status: MSP `account/read` over `muse serve --no-session-log --disable-write --disable-shell` |

Status mapping: Claude `loggedIn` true/false decides, except an explicit
API-key/Console/token `authMethod` is `auth_rejected`. Codex `Not logged
in`/`logged out` is disconnected, ChatGPT/logged-in/signed-in text is
connected, API-key/access-token text is `auth_rejected`, anything else is
`unexpected_output`. MSP `accountLogin` alone is connected, `loggedOut` is
disconnected, `envKey`/`apiKey` are `auth_rejected`, and unknown future
states fail safe — only the `state` member is read, labels/avatars/keys are
never extracted, and the serve child is reaped once answered.

Login mapping: child exit 0 is connected; nonzero is classified from
patterns (expiry → `expired`, auth failure → `auth_rejected`, else
`unexpected_output`). API-key markers anywhere in login output abort
immediately with `auth_rejected`.

Official URL allowlist (query preserved, shown here with placeholders):

- Claude: `https://claude.com/cai/oauth/authorize?…`
- Codex: `https://auth.openai.com/codex/device` (optional query preserved)
- Muse: `https://auth.meta.com/oauth/device/?…`

## Verification

`bin/test unit` (339 tests incl. 56 new authentication tests) and `bin/rails
zeitwerk:check` pass. The authentication tests use scripted fake sessions,
fake clocks and `RbConfig.ruby` dummy subprocesses only: chunk splits (URLs,
ANSI escapes, OSC 8 hyperlinks), success/reject/unknown outputs, forged
URLs, API-key rejection, cancel, deadlines, output caps, stdin-only codes,
env confinement and process-group/FD cleanup. No live account, AI inference
or network is required.

Manual probes (read-only, empty homes, no login performed): CLI
`--help`/`--version`, `claude auth status --json` and `codex login status`
against empty config dirs, the `muse serve` initialize/initialized/
`account/read` exchange against an empty XDG home, and the offline
`muse schema generate-json-schema --experimental` export that pins the
`AccountState` shape. Local binaries were Claude 2.1.280, codex-cli 0.155.1
and Muse Code 1.4.0 (the worker image pins 2.1.283 / 0.157.1 / 1.4.0). One
early read-only `claude auth status` smoke run used the default config
before the empty-home discipline was set; it recorded nothing but the
`disconnected` state. No login command was ever executed and no host auth
cache contents were read.

Not verified here (left for post-deploy acceptance): the exact logged-in
`authMethod` values and `login status` success texts (parsers accept the
documented positive signals and fail safe otherwise), the precise login
stdout layouts beyond the confirmed shapes (the scanner is defensive and the
URL policy is strict), and any real browser-approved login.

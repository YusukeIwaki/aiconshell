# Worker subscription authentication

The web tier records operations requests. Workers run the official CLIs and
retain long-lived credentials in private volumes. Authentication is separate
from business task execution; there is no arbitrary command or terminal API.

## Ruby contract

```ruby
runner = Aiconshell::Ai::Authentication::Runner.new(config: config)
runner.status(provider: "codex")
# {"state"=>"connected", "error_code"=>nil}
runner.login(provider: "claude", timeout: 900,
  on_challenge: ->(challenge) { ... },
  input: -> { nil }, cancelled: -> { false })
```

`config`, executable registry, process runner, interactive session factory and
monotonic clock are injectable. All results and challenges crossing this
boundary are validated against JSON Schema. Raw provider output, account
identifiers, exception text and credentials never leave it.

Status states are `connected`, `disconnected`, `unavailable`, `failed`. Login
also returns `cancelled` or `expired`. Failure codes are the fixed allowlist in
`Authentication::Result::ERROR_CODES`; unknown exceptions become `unknown`.
A missing executable is `unavailable`, not connected. A connected status
identifies the CLI's stored subscription-account mode; it does not prove a
live token, entitlement, available quota or successful AI inference.

`on_challenge` receives exactly:

```json
{"verification_uri":"https://official-provider/path", "user_code":null, "input_required":false}
```

Real URLs and user codes are temporary secrets. Examples/tests use synthetic
values. Only HTTPS with the provider's exact host/path is permitted; userinfo,
non-443 ports, fragments and control characters are rejected. Allowed paths:

- Claude: `https://claude.com/cai/oauth/authorize`
- Codex: `https://auth.openai.com/codex/device`
- Muse: `https://auth.meta.com/oauth/device/`

Queries are preserved for the official flow. OAuth scopes containing
`api_key` do not imply an API-key login; subscription mode is verified through
the official status interface. Muse's short user code is extracted from the
single `code` query parameter only after URL validation.

Claude's `input` callback is polled after the CLI stdin prompt. It returns nil
until a code is submitted, then a printable single line of at most 4096 bytes,
including the full `authorizationCode#state`. It is written to stdin once,
never argv. The UI consumes the encrypted input before this write. A crash
between consumption and write requires a fresh login; it cannot replay codes.

## Provider protocols

### Claude Code

`claude auth login --claudeai` runs with pipes and waits for the operator's
browser approval and pasted code. After exit zero,
`claude auth status --json` must report `loggedIn: true`,
`authMethod: "claude.ai"`, `apiProvider: "firstParty"` and exit zero.
`none` plus `loggedIn: false` is disconnected. API-key, helper, token and
third-party modes are rejected; incomplete/unknown shapes fail closed.

### Codex

Run `codex -c forced_login_method='"chatgpt"'
-c cli_auth_credentials_store='"file"' app-server --listen stdio://` using an
argv array. The stdio protocol is newline JSON **without** a `jsonrpc` member:

1. `initialize` with clientInfo and `experimentalApi: false`; wait for its
   correlated response, then send `initialized`.
2. Status: `account/read` with `refreshToken: false`.
3. Login: `account/login/start` with `type: "chatgptDeviceCode"`; validate the
   correlated result's type, loginId, verificationUrl and userCode.
4. Wait for `account/login/completed` with the **same loginId**, success true
   and no error. An `account/updated` notification alone is insufficient.
5. Read the account again: only `account.type: "chatgpt"`, a string planType
   and the required account/read shape count as connected. Null account is
   disconnected; API-key, Bedrock and unknown modes are rejected. Optional
   account metadata and future extra fields are not surfaced.
6. Cancellation/error sends `account/login/cancel` for the exact pending
   loginId, with a bounded response wait, then closes stdin and cleans up.

Notifications arriving before the start response are correlated by loginId.
Unknown response IDs never advance the protocol. The CLI owns token exchange
and persistence; the application never parses auth.json or JWTs.

### Muse Code

`muse login` starts the official device flow. Exit zero is provisional:
subscription mode is confirmed over the official MSP endpoint using
`muse serve --no-session-log --disable-write --disable-shell`.

Exchange newline JSON-RPC 2.0: `initialize` with `experimentalApi: true`, wait
for the response, send `initialized`, then parameter-less `account/read`.
The result must contain a boolean `credentialRequired`. Only state
`accountLogin` is connected; `loggedOut` is disconnected; `apiKey` and `envKey`
are rejected. Labels, avatars and unknown metadata are never returned.

## Process boundary and verification

Children receive array argv, an explicit environment with no application DB,
plugin or API-key credentials, and a dedicated provider auth cwd. Auth homes
and neutral HOME are private (0700). Input writes and output are bounded.
Cancellation/deadlines are checked while waiting and again after post-login
status verification. Status checks are bounded to 60 seconds or the remaining
login deadline. Every terminal path closes stdin/FDs and terminates the entire
process group, including descendants whose parent already exited.

Smartest tests use scripted CLI sessions, explicit synthetic JSON fixtures,
fake transports/clocks and harmless Ruby subprocesses. They cover protocol
ordering/correlation, malformed and non-subscription results, expiry/cancel,
secret-free failures, code consumption, output limits, stdin backpressure and
process/FD cleanup. No unit test needs a real account or network.

Manual acceptance used empty isolated homes in the pinned worker image:
Claude 2.1.283, Codex 0.157.1 and Muse Code 1.4.0. All three reported
`disconnected` offline, then exposed official login challenges and cancelled
successfully without browser approval. Real account approval, token refresh
and AI inference require the account owner and are separate checks.

Official protocol documentation:
- https://code.claude.com/docs/en/cli-reference
- https://learn.chatgpt.com/docs/app-server#authentication-modes
- https://learn.chatgpt.com/docs/auth
- Muse's installed `--help` and `schema generate-json-schema --experimental`

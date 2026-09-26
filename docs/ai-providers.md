# AI providers (subscription CLIs)

Three subscription CLIs sit behind one Ruby port (`Aiconshell::Ai::Runner`).
There is no API-key fallback: every call runs the provider's own CLI under the
account login, and unconfigured providers stay selectable but fail at
execution time.

## Contract

```ruby
Aiconshell::Ai::Registry.default.providers       # => ["claude", "codex", "muse"]
Aiconshell::Ai::Registry.default.configured?("codex") # presence diagnostic only
Aiconshell::Ai::Runner.new.call(
  provider: "codex", prompt: "...", schema: {},
  workspace: "/controlled/path", layer: "coordination",
  model: nil, effort: nil, instructions: nil, timeout: nil
) # => Hash, validated against schema
```

`model`, `effort` and `instructions` come from the admin LayerPolicy.
`configured?` checks only that the CLI exists on PATH and the private auth
location is mounted; subscription validity (expired login, usage limits) is a
runtime failure (`ExecutionFailed` with `kind` `:auth` or `:usage_limit`).

## Provider commands

| Provider | Headless invocation | Answer source |
| --- | --- | --- |
| Claude Code | `claude -p --output-format json --json-schema '<schema>' …` | `structured_output` of the `result` envelope (`subtype == "success"`) |
| Codex | `codex exec --json --output-schema <f> --output-last-message <f> … -` (prompt on stdin) | JSON object in the `--output-last-message` file |
| Muse Code | `muse exec --json --output-schema <f> --prompt-file <f> --workspace <dir> …` | `text` of the last `run.terminal.*` JSONL event, parsed as JSON |

Layer confinement:

- `interaction` / `coordination`: Claude runs with `--tools ""` and plan
  mode; Codex with `--sandbox read-only`; Muse with `--disable-write
  --disable-shell --disable-web-tools`. Nothing on disk can change.
- `execution`: Claude keeps workspace file tools with `acceptEdits`
  (anything that would prompt is denied); Codex uses `--sandbox
  workspace-write`; Muse runs without the disable flags. The workspace must
  be an isolated directory: the application body and every provider auth
  location are rejected as workspaces, as are relative paths.

Verified CLI surfaces: `claude --help` 2.1.280, `codex exec --help`
codex-cli 0.155.1, `muse exec --help` Muse Code 1.3.0, plus the official
Claude CLI reference / structured-outputs docs and offline `muse exec
--provider echo` probes (no login, no billed calls). Minimum versions for
the flags used here: Claude Code with `--json-schema`, `--permission-prompts`
and `--no-session-persistence` (2.1.259+), Codex with `--output-schema` /
`--output-last-message`, Muse Code 1.3.x with `--output-schema` /
`--prompt-file` / `--no-session-log`. Older CLIs fail fast with a classified
`ExecutionFailed` instead of silent misbehavior.

Notes and edges:

- Muse defaults to model `muse-spark-1.3-contributor` and reasoning effort
  `max`; both are configurable (`muse_default_model`, `muse_default_effort`,
  per-call `model:` / `effort:` overrides). Allowed efforts: Claude
  `low|medium|high|xhigh|max`, Codex `minimal|low|medium|high|xhigh`, Muse
  `none|minimal|low|medium|high|xhigh|max|ultra`. Anything else is rejected
  by deterministic Ruby validation before spawning.
- Codex and Muse have no system-prompt flag, so policy instructions are
  folded into the prompt document as `Instructions:… / Task:…`. Claude uses
  `--system-prompt`.
- The Claude prompt travels as a positional argv element (documented
  `claude -p "query"` form). Prompts starting with `-` may be misparsed by
  the CLI; that surfaces as `ExecutionFailed`, never as injection (argv
  arrays only, no shell anywhere).
- Processes run with `cwd = workspace`, their own process group, a timeout
  (default 300s), bounded stdout/stderr (default 1MB) and TERM-then-KILL
  group cleanup, so grandchildren cannot outlive the run.

## Login and credential homes

Use the official subscription login flows on a machine with a browser, then
persist only the resulting credential directories:

| Provider | Login | Credential home (presence-checked) | Child env override |
| --- | --- | --- | --- |
| Claude Code | interactive `claude` login or `claude setup-token` | `~/.claude` (`CLAUDE_CONFIG_DIR`, `AICONSHELL_CLAUDE_HOME`) | `CLAUDE_CONFIG_DIR` |
| Codex | `codex login` | `~/.codex` (`CODEX_HOME`, `AICONSHELL_CODEX_HOME`) | `CODEX_HOME` |
| Muse Code | `muse login` | `~/.config/muse` (`MUSE_CONFIG_DIR`, `AICONSHELL_MUSE_HOME`) | `MUSE_CONFIG_DIR`, optional `AICONSHELL_MUSE_XDG_CONFIG_HOME` → `XDG_CONFIG_HOME` |

The child environment is built from scratch (`unsetenv_others`): database,
GitHub, Jira, Teams and API-key variables are never inherited. Only a pinned
`PATH`, locale, a neutral `HOME`, `TMPDIR` and the calling provider's home
reach the CLI. Auth file contents are never read by this library and never
appear in errors, the EventLog, the database or admin pages; failure excerpts
are bounded (500 chars) and redacted. Never set `META_API_KEY`,
`OPENAI_API_KEY` or similar for these workers: API-key billing is out of
scope by design.

Token refresh is left to the CLIs themselves: keep the credential homes on
persistent volumes so refresh writes survive restarts. The Rails lane must
mount one private volume per provider (e.g. `/private/ai/claude`,
`/private/ai/codex`, `/private/ai/muse-config`) and point the `AICONSHELL_*`
overrides at them. The volumes must not be readable from the web/control
containers — only execution workers need them.

## Railway and Compose

Railway has no preinstalled AI CLIs; install pinned versions in the
execution-worker image (example shape, pin to the versions above):

```dockerfile
# Claude Code (npm), Codex (npm), Muse (vendor channel)
RUN npm install -g @anthropic-ai/claude-code@2.1.280 @openai/codex@0.155.1 \
 && curl -fsSL https://vendor.example.com/muse-1.3.0 -o /usr/local/bin/muse \
 && chmod +x /usr/local/bin/muse
```

Then attach the three private volumes and set the home overrides plus
`AICONSHELL_AI_HOME` (neutral child `HOME`). Compose mirrors the same
split: `web` / `control-worker` / `execution-worker` / `postgres` /
`clickhouse`, with provider volumes mounted only into `execution-worker`.

## Failure modes

| Symptom | Error | Meaning |
| --- | --- | --- |
| CLI or auth home missing | `NotConfigured` | Install the CLI / mount the volume |
| Timeout | `TimeoutError` (`Ai::Timeout`) | Whole process group was killed |
| Non-zero exit, login/auth text | `ExecutionFailed` (`:auth`) | Re-login, refresh expired grant |
| Usage/rate-limit text | `ExecutionFailed` (`:usage_limit`) | Back off; Coordination decides retries |
| Truncated / non-JSON / off-schema output | `InvalidOutput` | Includes JSON pointers, never values |

## Tests

`RBENV_VERSION=3.4.9 rbenv exec smartest smartest/ai/` runs the offline
suite: catalog, argv construction, parsing, schema validation, timeouts and
env filtering via a fake process runner, plus small real-subprocess boundary
tests (prompt piping, cwd, bounded output, TERM→KILL with grandchild
cleanup, no shell interpolation). Login flows and billed AI executions are
never triggered from tests.

## Runtime dependencies (for the Rails lane)

This lane does not touch the `Gemfile` (owned by issue #2). The Ai port
needs `json_schemer` (~> 2.5) at runtime and `smartest` (~> 0.6) for tests.
Everything else is Ruby stdlib (`json`, `tmpdir`, `open3`-free spawn,
`pathname`, `fileutils`).

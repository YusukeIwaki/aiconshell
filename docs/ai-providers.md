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

Layer CLI policy (not OS confinement — see Boundary below):

- `interaction` / `coordination` (read-only intent): Claude runs with
  `--tools ""`, plan mode, `--strict-mcp-config` (no `--mcp-config` is
  passed, so no MCP server loads) and `--disable-slash-commands` (no
  skills); Codex with `--sandbox read-only`, `--ignore-user-config` and
  `--ignore-rules`; Muse with `--disable-write --disable-shell
  --disable-web-tools --approval-mode never --no-foreign-personal-context`.
- `execution`: Claude keeps workspace file tools with `acceptEdits`;
  Codex uses `--sandbox workspace-write`; Muse runs without the disable
  flags. All layers deny anything that would prompt (Claude
  `--permission-prompts none`; Codex `exec` is non-interactive by design
  and the bypass flags are never passed; Muse
  `--user-input-auto-resolve` with approval and sandbox left ON).

Boundary: CLI flags are policy requests to a subprocess, not a sandbox.
`cwd`/`--add-dir`/`-C`/`--workspace` choose working roots — `--add-dir`
*grants* tool access to a directory, it does not confine Bash/Read to the
workspace — and Codex documents `--sandbox` as the policy for
model-generated shell commands only. The real isolation boundary is the
container / trusted-worker deployment: run CLIs in the execution worker
with a dedicated workspace directory, provider volumes mounted only there,
and no secrets in the child environment. The Ruby path guard rejects
workspaces that overlap provider auth locations (symlinks resolved) and
relative paths, but it does not sandbox the CLI and does not scan for
symlinks nested inside the workspace. The application-body separation is a
deployment property, not something this library enforces.

Verified CLI surfaces: `claude --help` 2.1.280, `codex exec --help`
codex-cli 0.155.1, `muse exec --help` Muse Code 1.4.0, plus the official
Claude CLI reference / structured-outputs docs and offline `muse exec
--provider echo` probes (no login, no billed calls). Minimum versions for
the flags used here: Claude Code with `--json-schema`,
`--permission-prompts`, `--no-session-persistence`, `--strict-mcp-config`
and `--disable-slash-commands` (2.1.259+), Codex with `--output-schema` /
`--output-last-message` / `--ignore-user-config` / `--ignore-rules`, Muse
Code 1.4.x with `--output-schema` / `--prompt-file` / `--no-session-log` /
`--user-input-auto-resolve` / `--approval-mode` /
`--no-foreign-personal-context`. Older CLIs fail fast with a classified
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
- Prompts never travel in argv: Claude and Codex receive the prompt on
  stdin, Muse via `--prompt-file`. Large prompts and prompts starting
  with `-` work, and user text never appears in the process list (argv
  arrays only, no shell anywhere).
- Processes run with `cwd = workspace`, their own process group, a timeout
  (default 300s), bounded stdout/stderr and result-file reads (default
  1MB) and TERM-then-KILL group cleanup. The deadline covers I/O too, and
  cleanup runs even when the parent exits promptly, so TERM-ignoring
  grandchildren holding pipes cannot outlive the run or wedge collection.

## Login and credential homes

Use the official subscription login flows on a machine with a browser, then
persist only the resulting credential directories:

| Provider | Login | Credential home (presence-checked) | Child env override |
| --- | --- | --- | --- |
| Claude Code | interactive `claude` login or `claude setup-token` | `~/.claude` (`CLAUDE_CONFIG_DIR`, `AICONSHELL_CLAUDE_HOME`) | `CLAUDE_CONFIG_DIR` |
| Codex | `codex login` | `~/.codex` (`CODEX_HOME`, `AICONSHELL_CODEX_HOME`) | `CODEX_HOME` |
| Muse Code | `muse login` | `<xdg>/muse` (`AICONSHELL_MUSE_HOME`, else `XDG_CONFIG_HOME`, else `~/.config`) | `XDG_CONFIG_HOME` + `MUSE_AUTH_PATH=<xdg>/muse/auth.json` |

The child environment is built from scratch (`unsetenv_others`): database,
GitHub, Jira, Teams and API-key variables are never inherited. Only a pinned
`PATH`, locale, a neutral `HOME`, `TMPDIR` and the calling provider's home
reach the CLI. Auth file contents are never read by this library and never
appear in errors, the EventLog, the database or admin pages; failures carry
only provider, kind and exit status (raw stdout/stderr is classified, then
discarded — no excerpts, redacted or otherwise). Never set `META_API_KEY`,
`OPENAI_API_KEY` or similar for these workers: API-key billing is out of
scope by design.

Token refresh is left to the CLIs themselves: keep the credential homes on
persistent volumes so refresh writes survive restarts. The Rails lane must
mount one private volume per provider (e.g. `/private/ai/claude`,
`/private/ai/codex`, `/private/ai/muse-xdg`) and point the `AICONSHELL_*`
overrides at them. The volumes must not be readable from the web/control
containers — only execution workers need them.

Muse layout note: `AICONSHELL_MUSE_HOME` is the XDG config home itself (the
directory *containing* `muse/`), not the `muse/` directory. The volume must
hold `muse/auth.json` (plus `muse/settings.json`, `muse/trust.json` as the
CLI maintains them). This is the only mapping honored by both stages:
verified against the installed `muse` launcher script
(`credential_path="${MUSE_AUTH_PATH:-$credential_default}"`, default
`$XDG_CONFIG_HOME/muse/auth.json` else `$HOME/.config/muse/auth.json`) and
the native runtime, which resolves the same XDG/HOME-rooted
`muse/auth.json` and honors neither `MUSE_CONFIG_DIR` nor `MUSE_AUTH_PATH`.
The child keeps a neutral `HOME`, so `XDG_CONFIG_HOME` is what preserves
access to the configured auth; `MUSE_AUTH_PATH` pins the launcher to the
same file. Auth file contents are never read (presence checks only) and
never copied into the repo.

## Railway and Compose

Railway has no preinstalled AI CLIs; install pinned versions in the
execution-worker image (example shape, pin to the versions above):

```dockerfile
# Claude Code (npm), Codex (npm), Muse (vendor channel)
RUN npm install -g @anthropic-ai/claude-code@2.1.280 @openai/codex@0.155.1 \
 && curl -fsSL https://vendor.example.com/muse-1.4.0 -o /usr/local/bin/muse \
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
suite: catalog, argv construction (no prompt in argv, layer tool policy,
noninteractive flags), parsing, schema validation, error sanitization
(unprefixed sentinels absent from errors), timeouts, symlink workspace
rejection and env filtering via a fake process runner, plus small
real-subprocess boundary tests (stdin piping, cwd, bounded output and
result files, TERM→KILL with grandchild cleanup even after parent exit,
spawn-failure FD cleanup, no shell interpolation). Login flows and billed
AI executions are never triggered from tests.

## Runtime dependencies (for the Rails lane)

This lane does not touch the `Gemfile` (owned by issue #2). The Ai port
needs `json_schemer` (~> 2.5) at runtime and `smartest` (~> 0.6) for tests.
Everything else is Ruby stdlib (`json`, `tmpdir`, `open3`-free spawn,
`pathname`, `fileutils`).

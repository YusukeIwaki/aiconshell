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
This diagnostic belongs to the executing worker. Admin pages use worker-confirmed
`AiConnection` snapshots instead; see [AI connections](ai-connections.md).

## Provider commands

| Provider | Headless invocation | Answer source |
| --- | --- | --- |
| Claude Code | `claude -p --output-format json --json-schema '<schema>' …` | `structured_output` of the `result` envelope (`subtype == "success"`) |
| Codex | `codex exec --json --output-schema <f> --output-last-message <f> … -` (prompt on stdin) | JSON object in the `--output-last-message` file |
| Muse Code | `muse exec --json --output-schema <f> --prompt-file <f> --workspace <dir> …` | `text` of the last `run.terminal.*` JSONL event, parsed as JSON |

Layer CLI policy (not OS confinement — see Boundary below):

- Every layer suppresses inherited connector/settings configuration: Claude uses
  `--setting-sources "" --strict-mcp-config --disable-slash-commands`; Codex uses
  `--ignore-user-config --ignore-rules`; Muse excludes foreign personal context.
- Codex additionally sets `forced_login_method="chatgpt"`, so a mounted API-login
  cache cannot select API-key billing. See the [official configuration reference](https://developers.openai.com/ja-JP/docs/config-file/config-reference).
- `interaction` / `coordination`: Claude has no tools, Codex uses its read-only
  sandbox, and Muse disables writes, shell, and web tools.
- `execution`: Claude explicitly allows Read/Edit/Write/Glob/Grep/Bash, Codex
  uses its workspace-write sandbox, and Muse retains its default sandbox.
- All layers run without approval prompts: Claude uses `--permission-prompts none`,
  Codex `exec` is noninteractive, and Muse uses both `--approval-mode never` and
  `--user-input-auto-resolve`. The latter only cancels model questions; it is not
  a substitute for the separate tool-approval mode.

Boundary: CLI flags are policy requests to a subprocess, not a sandbox.
`cwd`/`--add-dir`/`-C`/`--workspace` choose working roots — `--add-dir`
*grants* tool access to a directory, it does not confine Bash/Read to the
workspace — and Codex documents `--sandbox` as the policy for
model-generated shell commands only. The real isolation boundary is the
container / trusted-worker deployment: run CLIs in the unified execution
worker with dedicated workspace directories and private provider volumes,
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

Start the official subscription login on the unified execution worker
through the [AI connections admin page](ai-connections.md); the operator
approves the challenge in their browser. The worker itself needs no browser.
Persist the worker's own credential directories. Direct CLI login is also
available when operating that worker; the automated protocol is in
[ai-auth-protocol.md](ai-auth-protocol.md). The execution-side auth volumes
continue to be used; legacy control-side host volumes are neither mounted
nor deleted, and auth caches are never copied between volumes (old control
sessions expire through #20's ops entry in [AI connections](ai-connections.md)).

| Provider | Login | Credential home (presence-checked) | Child env override |
| --- | --- | --- | --- |
| Claude Code | interactive `claude` subscription login | `~/.claude` (`CLAUDE_CONFIG_DIR`, `AICONSHELL_CLAUDE_HOME`) | `CLAUDE_CONFIG_DIR` |
| Codex | `codex login` | `~/.codex` (`CODEX_HOME`, `AICONSHELL_CODEX_HOME`) | `CODEX_HOME` |
| Muse Code | `muse login` | `<xdg>/muse` (`AICONSHELL_MUSE_HOME`, else `XDG_CONFIG_HOME`, else `~/.config`) | `XDG_CONFIG_HOME` + `MUSE_AUTH_PATH=<xdg>/muse/auth.json` |

The child environment is built from scratch (`unsetenv_others`): database,
integration-account and API-key variables are never inherited. Only a pinned
`PATH`, locale, a neutral `HOME`, `TMPDIR` and the calling provider's home
reach the CLI. Auth file contents are never read by this library and never
appear in errors, the EventLog, the database or admin pages; failures carry
only provider, kind and exit status (raw stdout/stderr is classified, then
discarded — no excerpts, redacted or otherwise). Never set `META_API_KEY`,
`OPENAI_API_KEY` or similar for these workers: API-key billing is out of
scope by design.

Token refresh is left to the CLIs themselves: keep the credential homes on
persistent volumes so refresh writes survive restarts. Mount private credential directories (e.g. `/private/ai/claude`,
`/private/ai/codex`, `/private/ai/muse-xdg`) and point the `AICONSHELL_*`
overrides at them. Compose uses named volumes; Railway uses subdirectories
on the unified worker's single `/data` volume. One login set serves all
three layers on the unified worker. Web does not need them; its presence diagnostic is local to
the Web process and does not establish worker readiness.

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

Compose defaults the unified execution worker to the Docker `ai`
target, which bundles pinned Claude, Codex, and Muse CLIs. Muse is downloaded
from the official public Linux release with an architecture-specific SHA256
check; no login or auth cache is needed at build time. The `app` target used by
web contains no AI CLI. See [deployment.md](deployment.md) for build, volume,
and runtime login commands. Keep subscription credential volumes writable for refresh.
No real subscription login or billed model call is part of the automated tests.

## Failure modes

| Symptom | Error | Meaning |
| --- | --- | --- |
| CLI or auth home missing | `NotConfigured` | Install the CLI / mount the volume |
| Timeout | `TimeoutError` (`Ai::Timeout`) | Whole process group was killed |
| Non-zero exit, login/auth text | `ExecutionFailed` (`:auth`) | Re-login, refresh expired grant |
| Usage/rate-limit text | `ExecutionFailed` (`:usage_limit`) | Back off; Coordination decides retries |
| Truncated / non-JSON / off-schema output | `InvalidOutput` | Includes JSON pointers, never values |

## Tests

`RBENV_VERSION=3.4.9 rbenv exec bundle exec smartest smartest/ai/` runs the offline
suite: catalog, argv construction (no prompt in argv, layer tool policy,
noninteractive flags), parsing, schema validation, error sanitization
(unprefixed sentinels absent from errors), timeouts, symlink workspace
rejection and env filtering via a fake process runner, plus small
real-subprocess boundary tests (stdin piping, cwd, bounded output and
result files, TERM→KILL with grandchild cleanup even after parent exit,
spawn-failure FD cleanup, no shell interpolation). Login flows and billed
AI executions are never triggered from tests.

## Runtime dependencies

The Ai port uses `json_schemer` (~> 2.5) at runtime and `smartest` (~> 0.6) for tests.
Everything else is Ruby stdlib (`json`, `tmpdir`, `open3`-free spawn,
`pathname`, `fileutils`).

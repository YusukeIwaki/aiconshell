# Working agreements

## Coordination and implementation

For new work without an assigned implementation lane, use [the coordinating workflow](docs/issue-development.md):
create or refine the Issue, prepare an isolated issue branch/worktree, and prefer Muse Code
(`muse-spark-1.3-contributor`, `xhigh`) for implementation and verification.
Give it the Issue URL as the task entrypoint. Review independently before the authorized
main merge/push/closure. Do not create PRs. Work already assigned to an issue worktree
stays in that implementation lane; do not delegate it again just to satisfy this default.

## Skills by phase

Procedures live in project skills under `.agents/skills/` (read by Codex and Muse Code).
Open the one for the current phase; each is short and links to the canonical documents.

| Phase | Skill | Typical actor |
| --- | --- | --- |
| Requirements (要件の整理) | [aiconshell-requirements](.agents/skills/aiconshell-requirements/SKILL.md) | coordinator |
| Investigation (現状調査) | [aiconshell-investigation](.agents/skills/aiconshell-investigation/SKILL.md) | any, read-only |
| Issue planning (タスク化) | [aiconshell-issue-planning](.agents/skills/aiconshell-issue-planning/SKILL.md) | coordinator |
| Prioritization (優先度管理) | [aiconshell-prioritization](.agents/skills/aiconshell-prioritization/SKILL.md) | coordinator |
| Design and implementation (設計・実装) | [aiconshell-issue](.agents/skills/aiconshell-issue/SKILL.md) | implementation lane |
| Testing (テスト) | [aiconshell-testing](.agents/skills/aiconshell-testing/SKILL.md) | implementation lane, reviewer |
| Review and acceptance (検収) | [aiconshell-review](.agents/skills/aiconshell-review/SKILL.md) | coordinator |

When updating rules, put each rule in one place: hard constraints in this file, phase
procedures in the skill, standing product contracts in `docs/` (entry: `docs/development.md`).
Skills link to documents instead of copying them. Keep the `name` in the frontmatter equal to
the directory name, and confirm detection with
`muse skills list --source project --trust-workspace --json` after adding or renaming a skill.

## Start an implementation

When assigned a GitHub Issue, read it with `gh issue view NUMBER --json number,title,body,comments`.
Read [the issue implementation skill](.agents/skills/aiconshell-issue/SKILL.md),
then [the design map](docs/development.md) and only the linked documents relevant to the change.
The Issue specifies the requested behavior and acceptance criteria; repository documents supply
the standing contracts. Previous chats and personal agent configuration are not prerequisites.
Read `docs/architecture.md` before changing boundaries or public interfaces.

An assigned worktree is already the implementation workspace. Inspect its branch, status,
and base before editing; do not switch to the main checkout or create another worktree silently.
If an interface or dependency is missing, report the concrete conflict instead of inventing it.

## Constraints

- Work on one GitHub Issue per branch/worktree. Use `codex/issue-N-description`.
- Implement and verify in the assigned worktree. Never change another worktree.
- Do not create pull requests. Do not push, merge to main, or close issues from implementation sessions. The coordinating reviewer performs those actions after acceptance.
- Prefer Smartest (`smartest/**/*_test.rb`) and explicit fixtures. Unit tests must not require live accounts, AI calls, or network services. Database integration tests use PostgreSQL, not a SQLite substitute.
- Use Ruby 3.4.9 (`RBENV_VERSION=3.4.9 rbenv exec ...` on hosts with rbenv). Keep dependencies locked.
- Keep Interaction, Coordination, and Execution separate. Only Coordination makes task lifecycle and scheduling decisions. Controllers accept feedback and configure policies; they never invoke an execution worker directly.
- Validate plugin and AI inputs and outputs against JSON Schema. Inject transports, process runners, clocks, and event sinks for testing.
- Never commit credentials, auth caches, private volumes, `.env`, runtime logs, or model session transcripts. Never expose provider stdout/stderr or secrets in EventLog or error pages.
- AI subprocesses receive an explicit environment and a dedicated workspace, never application DB or integration credentials. No shell interpolation of user/AI text.
- Use official CLI subscription login flows; do not fall back to API-key billing. Unconfigured providers remain selectable but fail at execution.
- Web has no AI CLI or auth volume. Account state comes from worker-confirmed PostgreSQL snapshots. Authentication operations are separate from Task/TaskRun; see `docs/ai-connections.md`.
- Implement only the assigned issue scope. Document public contract changes, tests actually run, and unavailable verification honestly.
- Parallel lanes may own different namespaces. Do not edit another lane's files or resolve its interfaces by inventing incompatible alternatives.

## Commands

The Rails foundation defines `bin/test`, `bin/setup`, and `bin/jobs`.
Use [docs/testing.md](docs/testing.md) for exact commands and isolated PostgreSQL/ClickHouse setup.
On rbenv hosts: `RBENV_VERSION=3.4.9 rbenv exec bundle exec ./bin/test unit`.
For Rails: `RBENV_VERSION=3.4.9 rbenv exec ruby bin/rails zeitwerk:check`.
Run the relevant suite; run Zeitwerk when Rails wiring changes.
Commit accepted-scope changes locally and report checks actually run, skips and remaining work
using [the handoff format](docs/issue-development.md#handoff). Do not substitute a plan for implementation.

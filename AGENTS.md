# Working agreements

Read `docs/architecture.md` before changing boundaries or public interfaces.

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
- Implement only the assigned issue scope. Document public contract changes, tests actually run, and unavailable verification honestly.
- Parallel lanes may own different namespaces. Do not edit another lane's files or resolve its interfaces by inventing incompatible alternatives.

## Commands

The Rails foundation defines `bin/test`, `bin/setup`, and `bin/jobs`. Unit and integration command details live in README. Run the relevant suite and `bin/rails zeitwerk:check` when Rails wiring changes.

---
name: aiconshell-investigation
description: Investigate the current state of aiconshell (現状調査) — where a behavior lives, which contract governs it, which tests cover it, and what the Git/Issue history says — and report facts with file references. Use before writing requirements, splitting Issues, or when an implementation hits an unclear boundary.
---

# aiconshell investigation

Run from the repository root. Investigation is read-only: do not edit files, start
providers, log in to accounts, or post to external services.

1. Start from `docs/development.md` and pick the row for the area. Read that contract
   document and `docs/architecture.md` when a boundary or public interface is involved.
2. Locate the code and regression tests named in the table (`rg` over `app/`, `lib/`,
   `plugins/`, `smartest/`). Prefer the public service responsible for the behavior over
   nearby legacy helpers; note legacy/compat paths as such (for example `Admin::AiStatus.configured?`).
3. Check history only as needed: `gh issue list --state all`, `gh issue view N`, `git log -- PATH`.
   Treat `docs/verification.md` and `docs/issue-workflow-verification.md` as past measurements,
   not current specification.
4. Check what is running in parallel before recommending changes: `git worktree list`,
   open Issues, and uncommitted work you did not create. Never modify another worktree.
5. Distinguish verified facts (read in code/tests/run output) from inferences.

Output: current behavior with `path:line` references, governing documents, covering tests,
gaps or contradictions between docs and code, and related open Issues/worktrees.

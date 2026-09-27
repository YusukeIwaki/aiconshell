---
name: aiconshell-issue
description: Implement or fix an aiconshell GitHub Issue in its assigned worktree, using the project's design contracts, boundary fixtures and reviewer handoff. Use for repository implementation tasks received as an Issue number or URL.
---

# aiconshell Issue implementation

Run from the repository root. Paths below are relative to that root.

1. Read the assigned Issue, including acceptance criteria and later clarifications, with `gh`.
   Inspect `git status --short --branch` and the supplied base. Keep unrelated work intact.
2. Read `docs/development.md` for the design map. Follow its links for the affected boundary;
   do not load all manuals or infer architecture from a nearby legacy helper.
3. Follow the implementation lane in `docs/issue-development.md`. Reuse the existing public
   service responsible for the behavior. Changes to a contract include its maintained document.
4. Implement the Issue and verify with `docs/testing.md`. Keep domain services real and
   replace only the external boundary. Check durable state and forbidden side effects, not
   merely the response text or a mocked service call.
5. Review the diff against the Issue, commit in this branch, and return the handoff from
   `docs/issue-development.md#handoff`. The coordinating reviewer handles merge, push and closure.

If verification cannot run, explain the failed command and missing prerequisite. Do not
weaken assertions, replace PostgreSQL, enable live providers, or call a skipped check successful.
No instruction here authorizes production changes, account login or external test messages.

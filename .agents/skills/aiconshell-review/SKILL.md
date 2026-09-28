---
name: aiconshell-review
description: Independently review and accept an aiconshell Issue branch as the coordinator (検収) — check the diff against the Issue, rerun verification, send findings back to the same Issue, and perform the authorized main merge/push. Use after an implementation lane returns its handoff.
---

# aiconshell review and acceptance

Run as the coordinator. The procedure and the merge commands are defined in
`docs/issue-development.md` ("検収する人"); this skill is the checklist.

1. Read the Issue (body and comments) and the handoff. Do not accept on the report alone.
2. Review `git diff main...BRANCH` for: each acceptance criterion, layer boundaries in
   `AGENTS.md`/`docs/architecture.md`, side effects on failure, secrets/runtime logs/unrelated
   changes, and updated contract documents for any public contract change.
3. Check that new tests exercise real services and fail without the change
   (see `aiconshell-testing`). Rerun the relevant suites yourself in an isolated DB.
4. For defects, comment on the same Issue with reproduction and expected result, and
   return it to the same implementation lane. If the defect came from unclear docs, fix the
   canonical document or skill rather than writing a longer one-off prompt.
5. After acceptance, update main from origin, re-check conflicts if the base moved, then run
   the `--no-ff` merge and push described in `docs/issue-development.md`. Never create PRs.
   Pushing, merging and closing are outward-facing: do them only when authorized for this Issue.
6. Confirm the Issue closed, CI passed, and — for code changes — the Railway deployment.
   State plainly which of CI, deployment and real-account checks were not performed.

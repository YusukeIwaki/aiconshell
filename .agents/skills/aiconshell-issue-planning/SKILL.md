---
name: aiconshell-issue-planning
description: Turn clarified aiconshell requirements into GitHub Issues (タスク化) — one change per Issue, with dependencies, base and verification — so an implementation session can start from the Issue URL alone. Use when creating, splitting or refining development Issues.
---

# aiconshell issue planning

Run from the repository root as the coordinator. Input is a requirement summary from
`aiconshell-requirements` (or an equivalent request that already states its criteria).

1. Search for duplicates and related work: `gh issue list --state all --search KEYWORDS`.
   Refine an existing open Issue instead of creating a parallel one.
2. Split so that each Issue is one reviewable change with one branch/worktree
   (`codex/issue-N-description`). Separate independent changes; for dependent ones
   state the required Issue or base commit. Assign one owner lane per shared file or
   public interface when Issues may run in parallel.
3. Write the body with `.github/ISSUE_TEMPLATE/implementation.md`: purpose/current problem,
   observable acceptance criteria, non-goals, dependencies and contract documents, verification.
   Do not copy implementation steps or standing rules from `AGENTS.md`/docs into the Issue;
   link the contract document instead.
4. Record the priority with `aiconshell-prioritization` when the backlog order matters.
5. Creating or editing an Issue is outward-facing. Confirm the draft with the requester
   unless they have already authorized creation. Use `gh issue create --body-file FILE`
   so no user text is shell-interpolated.
6. Clarifications found later go to the same Issue as a comment with reproduction and
   expected result, not to a new private prompt.

Output: Issue URLs (or drafts), dependency order, and which can run in parallel.

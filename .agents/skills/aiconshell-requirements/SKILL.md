---
name: aiconshell-requirements
description: Clarify a raw aiconshell development request (要件の整理) into purpose, observable acceptance criteria, non-goals and open questions before any Issue or code is written. Use when a request is vague, mixes several changes, or conflicts with standing contracts.
---

# aiconshell requirements

Run from the repository root. This skill produces a requirement summary; it does not
create Issues or change code. Hand the result to `aiconshell-issue-planning`.

1. Restate the request as: who operates what, the current result, and the needed result.
   For a bug, capture the reproduction condition. Keep the requester's wording for UI copy.
2. Read `docs/development.md` and only the linked contract documents for the affected area.
   Mark each point as *new behavior*, *change to a standing contract* (name the document),
   or *already satisfied*. Use `aiconshell-investigation` when the current behavior is unclear.
3. Write acceptance criteria as observable results: normal path, important failure paths,
   and forbidden side effects (no Task/TaskRun, no external post, no secret in EventLog, …).
   Avoid prescribing class or queue names unless they are part of a public contract.
4. List non-goals explicitly, and separate independent changes so each can become one Issue.
5. Check the request against the constraints in `AGENTS.md` (layer separation, subscription
   login only, Web without AI CLI, credential isolation). Report a conflict concretely
   instead of silently reshaping the requirement.
6. Ask the requester only about decisions that change behavior and cannot be resolved from
   the repository. Record the rest as stated assumptions.

Output: purpose, acceptance criteria, non-goals, affected contract documents, assumptions,
open questions. Use the section names of `.github/ISSUE_TEMPLATE/implementation.md`.

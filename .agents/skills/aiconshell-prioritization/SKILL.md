---
name: aiconshell-prioritization
description: Manage the priority and order of this repository's development backlog (開発タスクの優先度管理) on GitHub Issues — labels P0–P3, dependencies and what to start next. Not for the application's own task triage/priority feature (see docs/workflow.md for that).
---

# aiconshell backlog prioritization

Run from the repository root as the coordinator. This skill orders development Issues;
it does not change the product's Coordination priority logic.

## Convention

| Label | Meaning |
| --- | --- |
| `P0` | Broken production path, security or data-loss risk. Start now; may interrupt other lanes. |
| `P1` | Needed for the current goal or blocks other Issues. Next to start. |
| `P2` | Planned improvement. Start when P0/P1 lanes are free. |
| `P3` | Nice to have or idea. May stay open without schedule. |

Dependencies are written in the Issue body (`依存・設計資料`) as Issue numbers; a blocked
Issue is not started before its dependency is merged, regardless of its label.
If the labels do not exist yet, propose creating them (`gh label create P0 …`) and create
them only after the requester agrees.

## Steps

1. List open Issues with labels and bodies: `gh issue list --state open --json number,title,labels,body`.
   Check active lanes with `git worktree list` and `git branch --list 'codex/issue-*'`.
2. Assign or adjust a label with a one-line reason (impact, urgency, dependency).
   Prefer unblocking Issues that others depend on. Avoid starting two lanes that change the
   same public interface; sequence them instead.
3. Propose the next Issue(s) to start and which can run in parallel. Changing labels is
   outward-facing: apply them only when the requester has asked for it or agreed.

Output: ordered list with label, reason, dependency and suggested lane.

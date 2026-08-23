---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Usage-limit dialog auto-resolve

Before a herdr `blocked` transition ever reaches this playbook, the watcher's push-transition handler (`handle_push_transition` in `bin/fm-push-transition-lib.sh`, via `fm_backend_autoresolve_blocked_dialog` in `bin/fm-backend.sh` and `fm_backend_herdr_autoresolve_usage_limit_dialog` in `bin/backends/herdr.sh`) already tried exactly one narrow, pattern-matched auto-resolve: Claude Code's usage-limit dialog ("What do you want to do? / Stop and wait for limit to reset / Ask your admin for more usage").
On an unambiguous match it sends the single safe keypress that selects "Stop and wait for limit to reset" and the wake never fires at all.
It is NEVER allowed to select "Ask your admin for more usage" - that is a cost-increase request and stays the captain's decision alone - and it fails closed (sends nothing) on any ambiguity, missing signal, or unexpected surrounding content.
A herdr `stale: ... waiting on human, escalated immediately` wake that DOES reach this playbook already failed that check, so treat it with the ordinary live-endpoint escalation below exactly as before this mechanism existed.

Only herdr implements this today (docs/verification/runtime-backends.md "Usage-limit dialog auto-resolve").
Every other verified backend has no equivalent native blocked-transition push (`fm_backend_has_push` is herdr-only), so the same dialog under tmux, zellij, orca, or cmux surfaces through the ordinary stale/wedge-timer path instead, unchanged, and this playbook's live-endpoint escalation is exactly how a human resolves it.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

For a REMOTE secondmate, `fm-crew-state` and `fm-peek` read the actual remote endpoint over `fm-on.sh`, and `fm-send` reports a delivered-with-pending-confirmation steer as delivered (their headers own the contracts); an `unknown-remote` read or unreachable-host failure means the remote state could not be read, never that the mate is dead or the send failed.
Recover a genuinely stuck remote mate only through `bin/fm-spawn.sh <id> --secondmate`, never raw herdr pane close/kill surgery, which strands the endpoint binding.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.

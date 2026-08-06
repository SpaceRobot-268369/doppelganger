---
name: work-in-worktree
description: Route a development task to the scope-matching doppelganger worktree or define and confirm a new worktree when none fits. Use when a task is described without a resolved worktree or the developer asks which worktree should own it.
---

# Skill: work-in-worktree

Route a development task into the **correct worktree**: match an existing one by
scope, or — if none fits — define the new worktree's behavior/scope, confirm it
with the developer, and delegate creation. Use when the developer describes work
to do and it isn't yet clear *where* it should happen, or asks "which worktree
should this go in?".

This is a **skill**: the agent judges which recorded scope best matches the task.
It **selects and routes only** — it does not perform the feature edits, and it
does not re-implement worktree creation.

## Deliberately not duplicated

The *rules* for routing and scoping already live in the agent files. This skill
**orchestrates** them; it must not restate or fork them:

- **Routing + scope-guard rules** →
  [`worktree-workflow.md` §1](../../context/dev-spec/worktree-workflow.md)
  (planning→execution routing) and
  [§8](../../context/dev-spec/worktree-workflow.md) (scope guard). These are the
  authority — link out, don't paraphrase.
- **Match source** (what each worktree is allowed to change) → canonical
  main-checkout `worktree-scopes.md` (tracked format:
  [`worktree-scopes.example.md`](../../memory/local/worktree-scopes.example.md)).
- **Creation** (branch/folder naming, bundle ID, bookkeeping) → the
  [`new-worktree`](../new-worktree/SKILL.md) skill. Never re-implement it here.
- **Principles 5 & 6** in [`AGENTS.md`](../../../AGENTS.md):
  `main`/`doppelganger-main` is read-only for authored tracked changes; edits
  must match the active worktree's scope. Clean fast-forward synchronization
  remains allowed.

The skill's only original responsibility is the **match/selection** step below,
which is not executable anywhere else today.

## Prerequisites

> Requires a git repo with `git worktree`. Read the registry from the **main
> checkout** (`doppelganger-main/`). If the canonical local files are missing,
> initialize them from the tracked examples there before matching. If
> `git worktree` is unavailable, tell the developer and point to
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md).

## Steps

1. **Gather the requirement.** Determine which files/areas the task will touch.
   Infer from the developer's prompt; if the target area is unclear, ask before
   matching.
2. **Inventory** the actual worktrees and their recorded scopes:
   ```bash
   git worktree list --porcelain
   ```
   plus the active entries in the canonical `worktree-scopes.md` (read from the
   main checkout; tracked format:
   [`worktree-scopes.example.md`](../../memory/local/worktree-scopes.example.md)).
   Note that `main`/`doppelganger-main` is read-only for authored tracked edits
   (Principle 5) and is intentionally not registered.
   When GitHub CLI access is available, refresh each active entry's PR number,
   URL, and PR Status using its branch before presenting the match. Apply the
   mapping in
   [`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md).
   External review changes are not assumed to be current without this refresh;
   if refresh fails, keep the recorded value and label it unverified in the
   report rather than inventing a replacement.
3. **Match** the requirement's target paths against each active worktree's
   **Scope**:
   - target ⊆ a worktree's scope → **strong match**,
   - partial / adjacent overlap → **candidate**,
   - no overlap → **miss**.
4. **Report and confirm** the resolution:
   - **One strong match** → propose routing there (`cd <worktree-path>`) and
     confirm before proceeding.
   - **Multiple candidates** → present a numbered list (folder, branch, scope)
     and ask which one.
   - **Almost fits** (scope would need widening) → offer the two §8 options:
     (a) expand the recorded scope for that worktree, or (b) use a new worktree.
     Do not silently widen a scope.
5. **Not found → define behavior first.** Propose the new worktree's **branch
   name, folder name, and scope** (the "behaviors"), and **confirm with the
   developer**. Then hand off to the
   [`new-worktree`](../new-worktree/SKILL.md) skill to actually create it — do
   not create it inline.
6. **Route.** State the resolved worktree's path and branch, governed by the
   scope guard (§8), then hand back to the developer. When this skill created a
   new worktree, the creation confirmation does not authorize task execution:
   do not edit, validate, or invoke an implementing skill until a subsequent
   developer message explicitly starts the task.

## Output

The resolved worktree the work should proceed in — an existing scope-matching
worktree, or a newly created one via `new-worktree` — plus a one-line reason for
the match (or the confirmed new scope). A newly created worktree is reported as
ready and awaits a subsequent developer message before task execution begins.

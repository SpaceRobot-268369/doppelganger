---
name: delete-worktree
description: Safely retire one or more doppelganger Git worktrees while preserving their branches and updating local bookkeeping. Use when the developer asks to delete, remove, retire, prune, or clean up worktrees.
---

# Skill: delete-worktree

Retire one or more doppelganger git worktrees without deleting their branches.
Use when the developer asks to delete, remove, retire, prune, or clean up a
worktree.

This is a **skill**: the agent inventories current worktrees, checks local
memory and working-tree state, asks which entries to retire, updates bookkeeping,
and removes only the selected worktree directories. It operates within the
Principles in `AGENTS.md` and the branch-preservation rule in
[`worktree-workflow.md` §9](../../context/dev-spec/worktree-workflow.md).

## Prerequisites

> Requires a git repo with `git worktree` available. If unmet, tell the developer
> exactly which prerequisite failed, point to
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> and stop.

Run from the main checkout (`doppelganger-main`) when possible. If invoked from a
different checkout, identify the main checkout from `git worktree list` and read
the local memory files there. If the current directory is inside a worktree
selected for deletion, stop and ask the developer to rerun from the main
checkout.

## Hard guardrails

- **Never delete branches.** Do not run `git branch -d`, `git branch -D`, or any
  branch deletion command. Report the preserved branch for every removed
  worktree.
- **Never remove the main checkout.** Show it for context if useful, but mark it
  as not deletable.
- **Never force-remove dirty work.** If a selected worktree has uncommitted or
  untracked changes, stop and ask whether the developer wants to commit, stash,
  or discard them. Do not use `git worktree remove --force` unless the developer
  explicitly confirms after seeing the dirty status.
- **Build cleanup is opt-in.** Detect an installed or running build from the
  recorded Bundle ID, report it, and ask before quitting or removing anything.
- **Agent memory must be updated.** Retiring a worktree means updating
  `.agents/memory/local/worktree-scopes.md` and appending a closeout note in
  `.agents/memory/local/parallel-work-log.md`.
- **An in-review PR keeps the worktree active.** Do not retire a worktree whose
  PR is draft, open/awaiting review, changes-requested, or approved but unmerged.
  The developer must first finish/merge the PR or explicitly abandon/close that
  review outside this skill. This skill never closes PRs.

## Steps

### 1. Inventory

Collect the actual git worktrees and local registry state. Read the memory files
from the main checkout path, not from a secondary worktree.

If either file is missing, initialize it from the corresponding tracked
`.example.md` file in the main checkout before inventorying entries.

```bash
git worktree list --porcelain
cat "<main-checkout>/.agents/memory/local/worktree-scopes.md"
cat "<main-checkout>/.agents/memory/local/parallel-work-log.md"
```

Build a numbered list that distinguishes:

- real non-main git worktrees,
- stale registry entries marked active but missing from `git worktree list`,
- retired registry entries,
- the main checkout (`doppelganger-main`, not deletable).

Include folder/path, branch, registry status, and whether the directory exists.
Also include PR number and PR Status.

### 2. Ask what to retire

Ask the developer which numbered worktree entry or entries to retire. Do not
delete anything before this confirmation.

If the developer selects a retired entry, explain that no removal is needed and
ask whether they only want a log note or no action.

### 3. Inspect selected entries

For every selected real worktree:

```bash
git -C "<worktree-path>" status --short --branch
```

Then inspect the selected entry's sections in:

- `.agents/memory/local/worktree-scopes.md`
- `.agents/memory/local/parallel-work-log.md`

Refresh the selected branch's live PR state before deciding whether it is
retirement-eligible:

```bash
gh pr list --head "<branch>" --state all --limit 1 \
  --json number,state,isDraft,url,reviewDecision,mergedAt,closedAt
```

Map the result per
[`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md) and write
it to the canonical registry. If GitHub state cannot be checked, report the PR
status as unverified and require developer confirmation before retirement.

Search those sections for unresolved notes such as `TODO`, `left off`, `open`,
`needs`, `blocked`, `Not pushed`, or equivalent wording. Report anything found
before removal.

Determine the **Bundle ID** from the registry entry first, then from the selected
worktree's `Local.xcconfig` if needed. If one is found, check for an installed or
running build:

```bash
mdfind "kMDItemCFBundleIdentifier == '<bundle-id>'"
pgrep -fl "<bundle-id>"
```

If a build is running, ask before quitting it. Do not delete built products,
DerivedData, or app-support containers unless the developer explicitly chooses
full cleanup — an app-support container may hold that worktree's saved
destinations and bookmarks.

### 4. Remove or retire

For selected real worktrees with clean status:

```bash
git worktree remove "<worktree-path>"
```

For selected stale active registry entries with no real directory, skip git
removal and only retire the local memory entry.

If the refreshed PR Status is draft, open/awaiting review, changes-requested, or
approved but unmerged, stop for that entry and leave it active. A merged PR is
only a retirement candidate: still require a clean worktree, no unique commits
or follow-up edits, and no unresolved notes.

After all selected real removals:

```bash
git worktree prune
```

Do not delete any branch.

### 5. Update local memory

Use today's absolute date (`date +%F`) and update the selected entries in
`worktree-scopes.md`:

- move each entry from `## Active worktrees` to `## Retired worktrees`,
- set **Status** to `retired`,
- note that the branch was preserved,
- note whether the worktree directory was removed or was already missing,
- note the merge/PR outcome when applicable,
- keep the original branch, scope, bundle ID, experiment, PR, PR Status, and
  created date,
- add **Retired** with today's absolute date.

Append a closeout note to `parallel-work-log.md` for each selected entry,
including:

- deletion date,
- whether a real worktree directory was removed or only stale registry state was
  retired,
- preserved branch,
- merge/PR outcome when applicable,
- any TODOs or notes found,
- build cleanup decision.

### 6. Verify and report

Verify the final state:

```bash
git worktree list
git branch --list "<branch-name>"
```

Report:

- removed worktree paths,
- stale entries retired,
- preserved branches,
- memory files updated,
- build cleanup performed or skipped,
- any unresolved notes the developer should carry forward.

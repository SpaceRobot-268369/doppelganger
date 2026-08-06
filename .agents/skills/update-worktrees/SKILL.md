---
name: update-worktrees
description: Fetch a remote base branch and safely update eligible Git worktrees using dirty-tree confirmation, conflict preflight, and protected-agent-file gates. Use when the developer asks to update, sync, fast-forward, or merge remote main into multiple worktrees.
---

# Skill: update-worktrees

Fetch the latest remote base branch and safely update every Git worktree attached
to the current repository. Use when the developer asks to update, sync,
fast-forward, or merge remote `main` into all worktrees, especially when they
want dirty worktrees confirmed first, conflicts skipped, and results reported in
a table.

This is a **skill**: the agent inventories the repo, judges which worktrees can
be updated safely, asks before touching dirty worktrees, merges only clean
conflict-free worktrees, and reports exactly what happened. It operates within
the Principles in `AGENTS.md`.

## Prerequisites

> Requires a Git repository with `git worktree` available and a reachable remote
> base branch. If unmet, tell the developer exactly which prerequisite failed,
> point to [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> and stop.

Default to `origin/main` unless the developer names another remote branch.

## Hard guardrails

- **Never push.** This skill only fetches, preflights, and performs approved
  updates. Prefer fast-forwards, which create no commit. A non-fast-forward
  merge may create a merge commit and therefore requires the explicit approval
  gate in Step 7 (Principle 4).
- **Never rebase, force-update, delete branches, prune branches, or rewrite
  history.**
- **Main is fast-forward only.** A clean `main`/`doppelganger-main` may
  fast-forward to remote `main` under Principle 5. Never create a local merge
  commit on main; skip and report dirty, divergent, or non-fast-forward main
  state.
- **Never merge dirty worktrees automatically.** Present them in a table and ask
  whether to skip, stash first, or allow Git to merge with local edits.
- **Skip conflicts.** If the preflight predicts conflicts, do not merge that
  worktree.
- **Abort only merges started by this skill.** If a real merge unexpectedly
  conflicts, run `git merge --abort` in that worktree, mark it skipped/failed,
  and continue with the remaining worktrees.
- **Agent files are change-protected.** Under Principle 1, any incoming update
  touching `AGENTS.md`, `CLAUDE.md`, `.agents/**`, or tracked provider
  configuration requires explicit developer approval before merging that
  worktree.
- **Do not hardcode paths.** Discover all worktrees with Git, not sibling folder
  names or doppelganger-specific paths.

## Steps

### 1. Identify repo and target

Confirm the current directory is inside a Git repo:

```bash
git rev-parse --show-toplevel
git rev-parse --git-common-dir
git remote -v
```

Set the update target:

- use the developer's requested remote branch if provided;
- otherwise use `origin/main`;
- verify it exists after fetch with `git rev-parse --verify <target>`.
- update a `main` checkout only when the target is its remote main
  (`origin/main` here); if another target was requested, skip main.

### 2. Fetch

Fetch before inspecting update state:

```bash
git fetch origin
```

If the target uses a different remote, fetch that remote instead. If fetch
fails, stop and report the failure; do not attempt local merges from stale refs.

### 3. Inventory all worktrees

Use Git's worktree registry:

```bash
git worktree list --porcelain
```

For every worktree path, collect:

```bash
git -C "<worktree>" rev-parse --abbrev-ref HEAD
git -C "<worktree>" rev-parse --short HEAD
git -C "<worktree>" status --short --branch
```

Treat detached HEAD, missing paths, or unreadable worktrees as skipped and report
the reason.

### 4. Classify protected agent-file changes

Classify incoming changes to these paths as approval-required:

- `AGENTS.md`
- `CLAUDE.md`
- `.agents/**`
- tracked provider configuration such as `.cursor/**` or `.codex/**`

For each worktree, inspect target changes against that worktree's `HEAD`:

```bash
git -C "<worktree>" diff --name-only HEAD...<target>
```

If protected paths appear, mark the worktree as `approval required` until the
developer explicitly approves that merge.

### 5. Preflight merge safety

For every readable worktree, check the commit relationship and predicted merge
safety without touching its working tree:

```bash
git -C "<worktree>" merge-base --is-ancestor <target> HEAD
git -C "<worktree>" merge-base --is-ancestor HEAD <target>
git -C "<worktree>" merge-tree --write-tree HEAD <target>
```

Interpretation:

- target is ancestor of `HEAD` -> already contains target; no merge needed.
- `HEAD` is ancestor of target -> fast-forward or normal merge is safe if
  protected-file approval is not pending.
- `merge-tree --write-tree` exits non-zero -> conflict predicted; skip.
- if `merge-tree --write-tree` is unavailable, use `git merge-tree $(git
  merge-base HEAD <target>) HEAD <target>` as a read-only fallback and inspect
  its output for conflict markers.

Do not run the real merge before the preflight table is shown.

### 6. Present preflight table

Before mutating anything, show a table:

| Worktree | Branch | State | Target delta | Protected agent-file risk | Conflict precheck | Proposed action |
|---|---|---|---|---|---|---|
| `/path/to/wt` | `feat/x` | clean | behind target | none | clean | fast-forward |
| `/path/to/docs` | `docs/y` | dirty | behind target | `.agents/**` | not checked | ask |

Rules for proposed actions:

- `already up to date` when no merge is needed.
- `fast-forward` only when clean, conflict-free, and no approval gate is pending.
- `ask` when dirty, protected agent-file approval is required, or updating a
  non-main worktree requires a merge commit.
- `skip` when conflict, detached HEAD, missing path, fetch failure, or unreadable
  state prevents a safe merge.
- For `main`, use `fast-forward` only; use `skip` for any divergent/non-fast-forward
  state.

For dirty worktrees, show the exact staged, unstaged, untracked, and conflicted
paths, then ask the developer to choose one of:

- skip dirty worktrees;
- stash first, update, then reapply the stash;
- allow an in-place **fast-forward only** while preserving non-overlapping local
  edits. This option is unavailable for a non-fast-forward update.

Default to skipping dirty worktrees when the developer does not clearly approve
another option.

### 7. Update approved safe worktrees

For `main`/`doppelganger-main`, and for every other worktree that can
fast-forward:

```bash
git -C "<worktree>" merge --ff-only <target>
```

If main cannot fast-forward, skip it. Do not create a merge commit on main.

If a non-main worktree cannot fast-forward but the merge preflight is clean,
show the developer the worktree, branch, target, and the fact that the operation
will create a merge commit. Only after explicit approval for that merge commit,
run:

```bash
git -C "<worktree>" merge --no-edit <target>
```

Record the resulting merge commit hash. A general request to inspect or preflight
worktrees is not approval to create it.

If the merge exits with conflicts:

```bash
git -C "<worktree>" merge --abort
```

Then mark the worktree as failed/skipped due to unexpected conflict. Do not
resolve conflicts inside this skill; hand off to
[`resolve-conflicts`](../resolve-conflicts/SKILL.md) if the developer wants
conflict resolution.

For dirty worktrees where the developer explicitly chose stash-first, stash
tracked and untracked changes before updating:

```bash
git -C "<worktree>" stash push -u -m "update-worktrees before merging <target>"
```

Then use `merge --ff-only` when possible. If the update needs a merge commit,
show that fact and require the separate merge-commit approval before running
`merge --no-edit`. After a successful update, run `stash pop`.

If the update fails after stashing, abort only a merge started by this skill,
reapply the stash when safe, and report both the update and restore results. Do
not leave a successful stash hidden without telling the developer.

For dirty worktrees where the developer explicitly chose in-place update, run
only:

```bash
git -C "<worktree>" merge --ff-only <target>
```

Git must preserve the local changes or refuse before updating. If it refuses,
stop and report; do not automatically stash, reset, force, or escalate to a
merge commit.

If `stash pop` conflicts, stop in that worktree, report it clearly, and hand off
to `resolve-conflicts`; continue only when doing so will not hide the conflicted
state from the developer.

If a dirty worktree needs a merge commit, only skip or stash-first are valid.
Require explicit approval for both the stash workflow and the merge commit; do
not infer one from the other.

### 8. Verify and report

After all attempted updates, collect final status:

```bash
git -C "<worktree>" status --short --branch
git -C "<worktree>" rev-parse --short HEAD
```

Report one final table:

| Worktree | Branch | Start HEAD | End HEAD | Action | Result | Notes |
|---|---|---|---|---|---|---|
| `/path/to/wt` | `feat/x` | `abc1234` | `def5678` | merge | merged | fast-forward |
| `/path/to/docs` | `docs/y` | `abc1234` | `abc1234` | skip | skipped | dirty; needs confirmation |

Use these result labels:

- `merged`
- `already up to date`
- `skipped: dirty`
- `skipped: conflict predicted`
- `skipped: protected agent-file approval required`
- `skipped: detached or unreadable`
- `failed: <reason>`

End by stating that no pushes, rebases, branch deletions, or force operations
were performed. List every merge commit created with its worktree and hash; if
none were created, state that all successful updates were fast-forwards and no
commit was created.

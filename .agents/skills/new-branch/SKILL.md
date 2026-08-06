---
name: new-branch
description: Commit approved current work, synchronize the latest remote main, and create a convention-named Git branch after confirming its name. Use when the developer asks to start or create a new branch outside the default worktree workflow.
---

# Skill: new-branch

Start a new working branch: commit the current branch's work, sync the latest
remote `main`, then create a properly named branch derived from the user's prompt.

## Execution style

This is a **low-freedom skill**: execute the steps in order. The only judgment step
is deriving the branch name (step 3), which is always confirmed with the user
before the branch is created.

## Prerequisites

> Requires a git repo with an `origin` remote, and (for step 1) the `commit`
> skill's prerequisites. If anything is unmet, tell the dev and guide setup via
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> then stop.

Use this only in a traditional single-checkout clone, and only when the developer
has explicitly asked for the branch-based flow — worktrees are the default (see
[`worktree-workflow.md` §1](../../context/dev-spec/worktree-workflow.md)). If the
checkout is `doppelganger-main/`, or `main` is checked out in a separate
registered worktree, route to [`new-worktree`](../new-worktree/SKILL.md) instead;
never turn `doppelganger-main/` into an implementation checkout (Principle 5).

## Steps

### 1. Commit current work

If the working tree has uncommitted changes, run the
[`commit`](../commit/SKILL.md) skill to commit them (it keeps its own approval
gate, Conventional Commits format, and new-file judgment — never commits without
user approval, Principle 4). If the tree is already clean, skip this step.

Do **not** switch branches with uncommitted changes still in the tree.

### 2. Sync latest remote main

```bash
git checkout main
git fetch origin
git pull --ff-only origin main
```

### 3. Derive and confirm the branch name

Build the name per
[`git-workflow.md`](../../context/dev-spec/git-workflow.md):

```
<type>/<short-kebab-description>
```

- **type:** `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `perf`, `build`,
  `ci`
- **description:** short kebab-case summary derived from the user's prompt

Infer each field from the user's prompt. **If any field is unclear, ask the user
instead of guessing.** Present the proposed branch name and get the user's
confirmation before creating it.

### 4. Create the branch

```bash
git checkout -b <confirmed-branch-name>
```

### 5. Offer to push (do not push automatically)

The branch stays local. Offer to set upstream, and run it **only after explicit
user approval** (Principle 4):

```bash
git push -u origin <confirmed-branch-name>
```

## Failure handling

Report the failure and the reason, e.g.: commit step declined/failed, `git pull`
conflict or non-fast-forward on `main`, branch name already exists, or the prompt
lacked enough info to name the branch (then ask).

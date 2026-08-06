---
name: new-worktree
description: Create and configure a doppelganger Git worktree from fresh origin/main with confirmed naming, an isolated bundle identifier, scope registration, and local logging. Use when the developer asks for a new worktree; creation approval never authorizes implementation of the requested task.
---

# Skill: new-worktree

Create a new **git worktree + branch** for parallel development: confirm the
umbrella layout, create the worktree off fresh `origin/main`, assign its build
identity, and record the worktree's scope and log entry.

## Execution style

This is a **low-freedom skill**: execute the steps in order. Derive and confirm
the branch name, folder name, and change **scope** together in Step 3 before
anything is created.

That confirmation authorizes this skill's creation/configuration work only.
It does not authorize the task described with the request; after step 7, wait
for a subsequent developer message explicitly asking to start that task. The
authoritative rule is
[`worktree-workflow.md` §1](../../context/dev-spec/worktree-workflow.md).

See [`../../context/dev-spec/worktree-workflow.md`](../../context/dev-spec/worktree-workflow.md)
for the full spec (this skill implements it).

## Prerequisites

> Requires a git repo with an `origin` remote and `git worktree` (git ≥ 2.5). If
> anything is unmet, tell the dev and guide setup via
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> then stop.

Unlike [`new-branch`](../new-branch/SKILL.md), the current working tree does
**not** need to be clean — a worktree is a separate checkout and never disturbs
the tree you are in.

## Steps

### 1. Confirm the on-disk layout

Worktrees live in the umbrella `doppelganger/` folder alongside the main checkout
`doppelganger-main/` (see
[`worktree-workflow.md` §2](../../context/dev-spec/worktree-workflow.md)). The
parent for new worktrees is that umbrella folder — the directory that *contains*
`doppelganger-main/`.

**If the layout is not as expected** (no `doppelganger-main/`, or the umbrella
can't be determined), **stop and confirm the intended location with the
developer** before creating anything. Never relocate worktrees by hand — use
`git worktree move` / `git worktree repair`.

### 2. Sync fresh remote main

```bash
git fetch origin
```

### 3. Derive and confirm the branch, folder, and scope

Build the branch per
[`../../context/dev-spec/git-workflow.md`](../../context/dev-spec/git-workflow.md):

```
<type>/<short-kebab-description>
```

Then derive the worktree folder per the naming rule in
[`worktree-workflow.md` §3](../../context/dev-spec/worktree-workflow.md):
`doppelganger-<type>-<feature>`.

Infer each field from the developer's prompt. **If any field is unclear, ask
instead of guessing.** For a variant/experiment set (developer wants several
options implemented to compare), derive one `-v<N>-<label>` branch+folder per
variant and a shared experiment id (see
[`worktree-workflow.md` §4](../../context/dev-spec/worktree-workflow.md)).

Identify the main checkout with `git worktree list --porcelain` and read its
canonical active scope registry when present. Infer the new worktree's **Scope**
as concrete paths/areas it may change; if the task area is unclear, ask rather
than guessing.

Present the proposed branch name(s), folder name(s), and scope(s) together. Get
one explicit confirmation covering all three before creating anything. That
confirmation still authorizes setup only, not task implementation.

### 4. Create the worktree + branch

```bash
git worktree add -b <branch-name> "<parent>/<folder-name>" origin/main
```

Repeat per variant for an experiment set. The branch is created at add time —
do not pre-create it.

### 5. Assign the build identity

Per [`worktree-workflow.md` §7](../../context/dev-spec/worktree-workflow.md),
each worktree builds under its own bundle identifier so parallel builds do not
share an install location, app-support container, or `UserDefaults` domain:

```
com.lucastao.doppelganger.<worktree-slug>
```

where `<worktree-slug>` is the folder name minus the `doppelganger-` prefix. For
example `doppelganger-feat-xxhash-checksum` →
`com.lucastao.doppelganger.feat-xxhash-checksum`.

Once the Xcode project exists, write it into a git-ignored `Local.xcconfig` at
the worktree root:

```
PRODUCT_BUNDLE_IDENTIFIER = com.lucastao.doppelganger.<worktree-slug>
```

**Until the Xcode project exists**, derive and record the identifier in the
registry anyway, and tell the developer the xcconfig step was skipped because
there is no project to consume it. Do not invent build files.

### 6. Register the confirmed scope and log

Use the scope confirmed in Step 3. Write it to the two canonical git-ignored
files under `<main-checkout>/.agents/memory/local/`; do not create a separate
registry copy in the new worktree.

If either canonical file is missing, create it from the corresponding tracked
`.example.md` file in the main checkout before updating it. Then:

- **`worktree-scopes.md`** — append under `## Active worktrees`: Folder, Branch,
  Scope, Bundle ID, Experiment id (if any), PR `—`, PR Status `not opened`,
  Status `active`, Created (today's absolute date).
- **`parallel-work-log.md`** — open a section for the new worktree.

The recorded scope is what the **scope guard** (Principle 6) enforces on all
later edits. These generated files are routine local bookkeeping: keep them
git-ignored and never stage or commit them.

### 7. Report

Tell the developer the new worktree path, branch, and assigned bundle identifier,
and how to enter it:

```bash
cd "<parent>/<folder-name>"
```

Do not build or run anything automatically.

End the current interaction after this report. Do not begin task analysis,
implementation, validation, or invoke an implementing skill from the creation
confirmation; wait for the developer's next message to explicitly start the
task.

## Failure handling

Report the failure and reason, e.g.: layout not as expected (asked to confirm),
branch already exists or is checked out in another worktree, folder already
exists, `git fetch` failed, no `origin` remote configured, or the prompt lacked
enough info to name the branch (then ask).

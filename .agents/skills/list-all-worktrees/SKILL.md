---
name: list-all-worktrees
description: Fetch remote main and produce a numbered, read-only inventory of every doppelganger Git worktree with the current checkout marker, branch and HEAD, detailed dirty state, ahead/behind counts versus local main and origin/main, scope, live PR status, installed-build state, and conservative deletion readiness. Use when the developer asks to list all worktrees, compare worktree commits, check which worktrees are dirty, inspect PR state, or see what is ready to delete.
---

# Skill: list-all-worktrees

Produce a fresh, numbered worktree status report. This is a **read-only reporting
skill**: fetching remote refs is allowed, but never merge, commit, push, stash,
edit local memory, or delete anything.

## Prerequisites

Require a Git repository with `git worktree`. Use `gh` when available; its
absence must not block the Git inventory. If `origin/main`, GitHub, or local
memory cannot be refreshed, retain the row and label the affected fields
`unverified` rather than inventing a value.

## Steps

### 1. Refresh references and locate authoritative checkouts

```bash
git rev-parse --show-toplevel
git worktree list --porcelain
git fetch origin main
git rev-parse --verify main
git rev-parse --verify origin/main
```

Fetching updates remote-tracking refs only. Do not update local `main` or any
worktree. If fetch fails, continue with cached `origin/main` when it exists and
mark the remote comparison stale; otherwise mark it unavailable.

Identify:

- the checkout containing the current working directory;
- the worktree whose branch is `refs/heads/main`;
- the canonical local registry and log under that main checkout at
  `.agents/memory/local/`.

### 2. Build the numbered inventory

Use `git worktree list --porcelain` as the authority for real worktrees. Order
rows deterministically:

1. current worktree;
2. local-main worktree, when different;
3. remaining real worktrees alphabetically by folder name;
4. active local-registry entries missing from Git, labelled `stale registry`.

Do not list retired registry entries as real worktrees. Mention their count
separately only when useful.

### 3. Collect Git state for every real worktree

```bash
git -C "<path>" rev-parse --abbrev-ref HEAD
git -C "<path>" rev-parse HEAD
git -C "<path>" log -1 --format='%h %cs %s'
git -C "<path>" status --porcelain=v1 --branch
git -C "<path>" rev-list --left-right --count main...HEAD
git -C "<path>" rev-list --left-right --count origin/main...HEAD
```

For each `rev-list` result, the first number is commits present only on the
comparison main (`behind`); the second is commits present only on the worktree
(`ahead`). Render it as `ahead N / behind M`. Do not reverse these values.

Classify dirty state from porcelain output:

- `clean` only when there are no staged, unstaged, untracked, or conflicted paths;
- otherwise show counts separately: `staged N · unstaged N · untracked N · conflicts N`;
- show detached, locked, prunable, missing, or unreadable states explicitly.

Also report configured upstream ahead/behind when it adds information not already
shown by the `origin/main` comparison.

### 4. Add scope and live PR state

Read the matching active entry from canonical `worktree-scopes.md` and the
matching section from `parallel-work-log.md`. Include a concise scope summary,
recorded PR, and recorded PR Status.

When `gh` is authenticated, refresh the branch's live PR without updating local
memory:

```bash
gh pr list --head "<branch>" --state all --limit 1 \
  --json number,state,isDraft,url,reviewDecision,mergedAt,closedAt,headRefOid
```

Map it to the statuses defined in
[`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md):
`not opened`, `draft`, `open — awaiting review`, `changes requested`,
`approved — awaiting merge`, `merged — retirement check pending`, or
`closed/abandoned`. Prefer live state and label registry-only state `recorded,
unverified` when GitHub cannot be queried.

### 5. Check installed-build state

Get the worktree's **Bundle ID** from the registry, falling back to its
git-ignored `Local.xcconfig` when present. Report, without changing anything,
whether a build under that identifier is currently installed or running:

```bash
mdfind "kMDItemCFBundleIdentifier == '<bundle-id>'"
pgrep -fl "<bundle-id>"
```

Report `none`, `installed`, `running`, or `unverified`. Before the Xcode project
exists there is nothing to find; report `none — no project yet`. Never quit an
app or delete a build in this skill.

### 6. Calculate conservative deletion readiness

Use one of four labels and list every blocker or uncertainty:

- **`READY`** — all required checks passed.
- **`READY AFTER CLEANUP`** — otherwise ready, but an installed or running build
  must be handled through `delete-worktree`.
- **`NOT READY`** — a confirmed blocker exists.
- **`REVIEW REQUIRED`** — required GitHub, build, merge, or local-memory facts
  cannot be proven safely.

Apply these rules:

1. `main`/`doppelganger-main` is `NOT DELETABLE — MAIN`.
2. Any staged, unstaged, untracked, or conflicted path is `NOT READY`.
3. Any draft, open, changes-requested, or approved-but-unmerged PR is
   `NOT READY`.
4. Treat the work as integrated when either:
   - `git merge-base --is-ancestor HEAD origin/main` succeeds; or
   - a live PR is merged and current `HEAD` exactly equals that PR's
     `headRefOid`, proving there are no local commits after the merged PR head.
5. A merged PR with a different current HEAD is `NOT READY` until the extra
   commits are explained. A merged PR without a verifiable `headRefOid`, or a
   branch that may have been squash/rebase merged but cannot be proven, is
   `REVIEW REQUIRED`.
6. A closed, unmerged PR is eligible only when abandonment is explicitly recorded
   in the registry/log; otherwise use `REVIEW REQUIRED`.
7. Relevant unresolved notes such as `TODO`, `left off`, `blocked`, `needs`,
   `Not pushed`, or requested follow-up make it `NOT READY` until resolved or
   explicitly carried forward.
8. A running or installed build produces `READY AFTER CLEANUP` only when every
   other check passes. Unknown build state produces `REVIEW REQUIRED`.
9. Missing/unverified PR state, missing canonical memory, unreadable worktrees,
   or ambiguous integration state produces `REVIEW REQUIRED`, never `READY`.
10. A stale active registry entry has no directory to delete; label whether its
    bookkeeping appears ready to retire separately.

This is an advisory classification. Actual removal always uses
[`delete-worktree`](../delete-worktree/SKILL.md), which refreshes the checks and
asks for the required cleanup/removal confirmation.

### 7. Present the report

Render the result with
[`assets/report-template.md`](assets/report-template.md). Treat that file as the
output contract: preserve its table columns, numbering, verification summary,
and rendering rules. Replace every placeholder with observed data or an explicit
`unavailable`/`unverified` value. Include numbered detail blocks only when they
add scope, blocker, uncertainty, or stale-registry information that cannot be
expressed clearly in the table.

## Failure handling

Always return the partial inventory when safe. Label per-field failures such as
fetch unavailable, missing local `main`, detached HEAD, GitHub unauthenticated,
or malformed registry entries. Stop entirely only when the current directory is
not part of a readable Git repository.

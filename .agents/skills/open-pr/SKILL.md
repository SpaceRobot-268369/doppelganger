---
name: open-pr
description: Get the current branch pull request into open, ready-for-review status after explicit approval. Use when the user asks to send, open, publish, or promote a PR for review, whether or not a draft already exists.
---

# Skill: open-pr

Get the current branch's pull request to **open** status (ready for review).
Complements [`draft-pr`](../draft-pr/SKILL.md), which only ever creates a
*draft* PR.

This is a **skill**: the agent decides whether to promote an existing draft or
compose and open a new PR. It operates within the Principles in `AGENTS.md` — it
never pushes or opens/promotes a PR without explicit user approval (Principle 4).

## When to use

When the user wants to **send / open a PR** (make it ready for review), whether or
not a draft already exists.

## Prerequisites

> Requires `gh` authenticated (`gh auth status`) and a git repo with an `origin`
> remote. If unmet, tell the dev and guide setup via
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> then stop.

## Steps

### 1. Detect existing PR for the current branch

```bash
git rev-parse --abbrev-ref HEAD
gh pr view --json number,state,isDraft,url 2>/dev/null
```

- **A draft PR exists** → go to Step 2 (promote).
- **An open PR already exists** → synchronize its current PR fields into
  canonical local memory, report its URL, and stop.
- **No PR exists** → go to Step 3 (compose + open).

### 2. Promote an existing draft → open

Confirm with the user, then mark it ready for review:

```bash
gh pr ready <number>
```

Report the PR URL and its new `OPEN` status.

Update the canonical main-checkout `worktree-scopes.md` entry with the PR
number/URL and PR Status `open — awaiting review`; append a dated note to
`parallel-work-log.md`. Keep worktree Status `active`.

### 3. No PR yet → compose and open

Reuse the [`draft-pr`](../draft-pr/SKILL.md) composition (file-change tree +
`template.md`, including its offload-engine verification rule). Then, **after
user approval**:

1. Base branch is always `main`.
2. Ensure the branch is pushed: `git push -u origin <branch>` (never `--force`).
3. Create the PR **open** (note: **no** `--draft` flag):
   ```bash
   gh pr create --base main --title "<title>" --body "<body>"
   ```
4. Update canonical local memory with the PR number/URL and PR Status
   `open — awaiting review`; append a dated work-log note. Keep worktree Status
   `active`.
5. Return the PR URL.

For an already-open PR, use its live `reviewDecision` to apply the PR Status
mapping in
[`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md), rather
than overwriting `changes requested` or `approved — awaiting merge` with the
generic awaiting-review value.

If the PR action succeeds but local-memory updating fails, do not roll back or
close the PR. Report the bookkeeping failure and successful PR URL separately.

## Approval gate (required)

Opening a PR signals "ready for review." **Do not push, create, or promote until
the user explicitly approves.**

## Relationship to draft-pr

- `draft-pr` — compose + create a **draft** PR.
- `open-pr` — ensure the PR is **open**: promote an existing draft, or compose +
  create an open PR if none exists. Shares `draft-pr`'s composition so the body
  format stays identical.

## Failure handling

Report the reason on failure, e.g.: `gh` not authenticated, branch has no commits
ahead of `main`, push rejected / no remote, or `gh pr ready` failing because no PR
exists (then fall back to Step 3).

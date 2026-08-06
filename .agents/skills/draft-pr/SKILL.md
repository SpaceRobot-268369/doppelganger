---
name: draft-pr
description: Draft a pull request from the current branch and, after explicit approval, push and create it while updating local worktree memory. Use when the user asks to draft, prepare, or open a draft PR for review.
---

# Skill: draft-pr

Draft a pull request for the current branch and, on user approval, create it.

This is a **skill**: the agent has decision power over how to summarize the work
into a clear title and body. It still operates within the Principles in
`AGENTS.md` — it never pushes or opens a PR without explicit user approval
(Principle 4).

## When to use

When the user wants to open a PR, draft a PR description, or prepare the current
branch for review.

## Prerequisites

> Requires `gh` authenticated (`gh auth status`) and a git repo with an `origin`
> remote. If unmet, tell the dev and guide setup via
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> then stop.

> **Branch must be up to date with `origin/main`.** Fetch first, then check
> `git merge-base --is-ancestor origin/main HEAD`. If synchronization is needed,
> preflight it with `git merge-tree --write-tree HEAD origin/main`, show whether
> it will fast-forward or create a merge commit, disclose any protected agent
> files in the incoming delta, and get explicit developer approval before
> merging. If conflicts are predicted, hand off to
> [`resolve-conflicts`](../resolve-conflicts/SKILL.md). Never `--force` or rewrite
> shared history (Principle 4).

When approved, use `git merge --ff-only origin/main` when possible; otherwise
use `git merge --no-edit origin/main` and report the resulting merge commit hash.
This synchronization approval is separate from the later push/PR approval.

## Inputs to gather (read-only)

1. Current branch: `git rev-parse --abbrev-ref HEAD`.
2. Commits vs base: `git log origin/main..HEAD --oneline`.
3. Files changed with status: `git diff --name-status origin/main...HEAD`
   (`A` = added, `M` = modified, `D` = deleted, `R` = renamed) and
   `git diff origin/main...HEAD --stat` for line counts.
4. Optionally inspect the substantive diff: `git diff origin/main...HEAD`.
5. Parse the branch shape — `<type>/<feature>` — to inform the title and confirm
   it follows the convention (see
   [`git-workflow.md`](../../context/dev-spec/git-workflow.md)).

If there are no commits ahead of `origin/main`, stop and tell the user there is
nothing to PR.

## Compose the draft (agent's judgment)

- **Title:** `<type>: <concise feature summary>` (e.g. `feat: streaming xxHash
  checksum`), aligned with the branch type and commit-message style in the repo.
- **Body:** follow the template stored alongside this skill, `template.md` — fill
  in:
  - **Summary** — what the PR does and why (1–3 sentences).
  - **Changes** — bulleted list of notable changes (derive from commits + diff).
  - **File changes** — render the changed files as a **tree structure** with a
    status marker per file derived from `git diff --name-status`:
    `+` added, `~` modified, `-` deleted, `>` renamed. Example:

    ```
    .agents/
    ├── + skills/draft-pr/SKILL.md
    └── ~ context/dev-spec/git-workflow.md
    AGENTS.md            ~
    CLAUDE.md            ~
    ```
  - **Verification** — how it was verified; if unknown, ask the user or leave a
    clear placeholder rather than inventing results.

### When the PR touches the offload engine

If the diff touches copy, checksum, verification, or manifest code, the
**Verification** section must state explicitly how the
[offload contract](../../context/product/offload-model.md) was exercised — which
fixtures, which failure modes, and whether verification was proven to re-read
from disk. Per Principle 3, "the tests pass" alone is not an acceptable answer
for this area.

## Approval gate (required)

Present the proposed title and body to the user. **Do not push or create the PR
until the user explicitly approves.**

## On approval — create the PR

1. Base branch is always `main`.
2. Ensure the branch is pushed: `git push -u origin <branch>` (never `--force`).
3. Create a **draft** PR:
   ```bash
   gh pr create --base main --draft --title "<title>" --body "<body>"
   ```
4. In the canonical main-checkout local memory, update the current worktree's
   `worktree-scopes.md` entry with the PR number/URL and PR Status `draft`.
   Append a dated `parallel-work-log.md` note that the draft PR was created.
   Keep worktree Status `active`.
5. Return the PR URL to the user.

If the PR is created but local-memory updating fails, do not roll back or close
the PR. Report the bookkeeping failure and the successful PR URL separately.

> To send the PR for review (open / ready status), use the
> [`open-pr`](../open-pr/SKILL.md) skill — this skill only ever creates a draft.

## Failure handling

If any step fails, report that it failed and include the reason(s), e.g.:
- `gh` not authenticated (`gh auth status`).
- Branch has no commits ahead of `main`.
- Push rejected / no remote.
- Branch name does not follow the convention (warn, ask whether to proceed).

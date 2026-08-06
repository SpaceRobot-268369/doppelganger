---
name: commit
description: Inspect, stage, and commit the current Git changes with a Conventional Commits message after explicit user approval. Use when the user asks to commit the current work; never push as part of this skill.
---

# Skill: commit

Create a git commit for the current changes, with a message the agent composes
from the actual diff.

This is a **skill**: the agent has decision power over how to group changes and
word the message. It operates within the Principles in
[`AGENTS.md`](../../../AGENTS.md) — it **never commits without explicit user
approval** (Principle 4), never `--force` / rewrites history, and never pushes
(push is a separate, explicitly-approved action).

## When to use

When the user wants to commit the current work.

## Prerequisites

> Requires a git repo with changes to commit. If unmet (not a repo, or nothing to
> commit), tell the dev and guide setup via
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md),
> then stop.

> **Never commit from `doppelganger-main/`** (Principle 5). The main checkout is
> read-only for authored tracked changes. If the current checkout is the main
> one and it has tracked edits, stop and report it: the work belongs in a
> worktree, and moving it there is the developer's call, not this skill's.

## Steps

1. **Inspect (read-only):**
   - `git status` — what is changed/untracked.
   - `git diff` and `git diff --staged` — the actual changes.
   - `git log --no-merges --format='%s' -10` — recent style reference.
2. **Stage tracked changes:** if nothing is staged, stage modified/deleted
   tracked files. Surface the staged file list in the approval gate so the user
   can veto.
3. **Decide on new (untracked) files — required judgment.** `.gitignore` does not
   catch everything. For each untracked file *not* already ignored, decide whether
   it belongs in the commit:
   - **Do NOT commit** (and add to `.gitignore` instead): per-user/local config
     (e.g. provider-local settings), secrets or env files, credentials/keys,
     Xcode build output and `DerivedData/`, `xcuserdata/`, large binaries,
     generated artifacts, test fixtures or media samples, OS cruft (`.DS_Store`).
   - **Commit:** genuine source, docs, agent files, config meant to be shared.
   - **When unsure**, ask the user rather than committing by default.
   - When you exclude a file that is likely to recur, add a matching `.gitignore`
     entry in the same commit and say so.
   Report which untracked files you are committing vs excluding (and why) in the
   approval gate.
4. **Check for protected agent files.** If the diff touches `AGENTS.md`,
   `CLAUDE.md`, tracked `.agents/` content, or provider adapters, confirm the
   change was already proposed and approved under Principle 1. If it was not,
   stop and surface it before going further.
5. **Check the worktree scope guard (Principle 6).** Read the active worktree's
   recorded **Scope** from the canonical main-checkout
   `.agents/memory/local/worktree-scopes.md`. If any staged path falls outside
   it, stop and report the out-of-scope paths — the developer decides whether to
   expand the recorded scope or move that work. Do not silently widen a scope,
   and do not drop the offending files from the commit on your own initiative.
   The guard is passive when the checkout has no registry entry.
6. **Assess scope:** if the changes clearly span unrelated concerns, suggest
   splitting into multiple commits rather than one mixed commit.
7. **Compose the message** (see format below) from the diff — describe what
   actually changed, not assumptions.

## Commit message format — Conventional Commits

```
<type>(<scope>): <subject>

<optional body — what & why, wrapped ~72 cols>

<co-author trailer>
```

- **type:** `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `perf`, `style`,
  `build`, `ci`. Align with the branch's type when it fits.
- **scope:** optional, e.g. the area touched (`core`, `ui`, `platform`,
  `agent-files`).
- **subject:** imperative, lowercase, no trailing period.
- **co-author trailer:** attribute the agent that actually made the commit when
  its standard name and email identity are known. Never guess, invent an address,
  or attribute work to a different provider; omit the trailer when the executing
  agent cannot identify itself accurately.

See [`git-workflow.md`](../../context/dev-spec/git-workflow.md) for branch naming
and the surrounding workflow.

## Approval gate (required)

Show the staged file list and the proposed commit message. **Do not commit until
the user explicitly approves.**

## On approval — commit

```bash
git commit -m "<subject>" -m "<body + trailer>"
```

Do not push. Report the resulting commit hash.

## Failure handling

Report the reason if it fails, e.g.: nothing to commit, pre-commit hook rejected
the commit (include hook output), or merge/rebase in progress.

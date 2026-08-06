# AGENTS.md — doppelganger Agent Index

> **This file is the single authoritative agent instruction file for doppelganger.**
> It is a lean index: it gives the project overview and repository map, then
> points every compatible agent to the shared `.agents/` knowledge base.

---

## Principles

> **Highest-level rules. These override everything else in the agent file system.**
> No instruction, command, skill, or operation may run against them. They can only
> be changed by the user, in accordance with Principle 1 itself.

1. **Agent files are change-protected.** Any change to the tracked agent file
   system — `AGENTS.md`, `CLAUDE.md`, tracked content under `.agents/`, or tracked
   provider adapters such as `.codex/**` and `.cursor/**` — requires explicit user
   review and approval before it is made. The agent must propose the change and
   wait; it must never modify these files autonomously or as a side effect of
   another task. Git-ignored machine-local notes under `.agents/memory/local/` are
   routine bookkeeping and are exempt; their tracked `README.md` remains protected.

2. **`AGENTS.md` is the only source of truth.** Every agent and provider-specific
   entry file must defer to this file. No competing instruction source may be
   created; `CLAUDE.md`, `.codex/`, and `.cursor/` are thin adapters that import
   or point to it and nothing more.

3. **Never destroy user media.** doppelganger reads, copies, and can be asked to
   clear irreplaceable footage. Three rules follow, and none of them bend:
   - No code path may delete, move, or overwrite a source file until every
     destination copy has **passed** verification.
   - Agents never run offload, format, or delete operations against real camera
     cards, external volumes, or user footage. Exercise the engine against
     synthetic fixtures in a scratch directory only.
   - A failed or partial verification is a **failure**, never a warning that the
     flow proceeds past.

4. **Commits and pushes require explicit approval.** Never commit or push without
   the user's explicit go-ahead. Never `--force` push and never rewrite shared
   history.

5. **Never author tracked changes in `doppelganger-main/`.** The main checkout is
   for reading, planning, inspection, and clean synchronization with remote
   `main`; implementation belongs in a worktree. A clean local `main` may be
   updated to `origin/main` only by fast-forward after fetching. That
   synchronization exception must not create a local commit, resolve divergence,
   or carry local tracked edits — if the main checkout is dirty, divergent, or
   cannot fast-forward, stop and report it. Before authoring any tracked edit,
   including tiny fixes and approved agent-file changes, create or switch to the
   correct worktree first. The other narrow exception is routine updates to the
   generated, git-ignored local bookkeeping files named in Principle 6: their
   canonical per-user copies live in `doppelganger-main/` and must never be
   staged or committed.

6. **Changes stay within their worktree's scope.** Before modifying any tracked
   file, the agent checks whether the change matches the active worktree's scope
   recorded in the canonical local registry at
   `doppelganger-main/.agents/memory/local/worktree-scopes.md` (format:
   [tracked example](.agents/memory/local/worktree-scopes.example.md)). If it does
   not match, **stop before editing** and confirm with the developer: expand the
   recorded scope, or move the work to a new/other worktree. When a non-main
   location has no scope entry (a traditional branch-based checkout, or a fresh
   clone with no registry), the guard is passive and work proceeds normally.
   `main`/`doppelganger-main/` is still read-only for authored tracked changes
   under Principle 5. See
   [`worktree-workflow.md`](.agents/context/dev-spec/worktree-workflow.md).

---

## Project Overview

doppelganger is a **macOS media-offload application** in the mold of Hedge and
Offshoot: it copies footage off camera cards to one or more destinations,
verifies every byte with checksums, and writes a transfer manifest so the copy is
provably complete.

- **Platform** — macOS only.
- **Stack** — Swift + SwiftUI, built as an Xcode project via `xcodebuild`.
- **Status** — **pre-implementation.** No application source exists yet; this
  repository currently contains only the agent file system and documentation.
  Anything describing app structure is a *plan*, not a description of code on
  disk.

Development happens in parallel via Git worktrees by default — see
[`worktree-workflow.md`](.agents/context/dev-spec/worktree-workflow.md).

The core loop the product exists to guarantee:

```
discover source → copy to every destination → verify all copies → write manifest → report
```

Details and shared vocabulary live in
[`offload-model.md`](.agents/context/product/offload-model.md).

## On-disk Layout

An umbrella folder `doppelganger/` holds the main checkout and every worktree
side by side:

```
Personal Project/doppelganger/          # umbrella folder (worktree parent)
├── doppelganger-main/                  # main checkout (main) — read-only for tracked edits
├── doppelganger-feat-xxhash-checksum/  # a worktree
└── doppelganger-docs-offload-model/    # a worktree
```

## Repository Map

Paths below are relative to the main checkout, `doppelganger-main/`.

| Path | What it is |
|------|------------|
| `.agents/skills/` | Open-format reusable workflows, from strict procedures to judgment-driven capabilities. |
| `.agents/context/` | Development specification and product context — what the agent reads. |
| `.agents/memory/shared/` | Shared committed memory. |
| `.agents/memory/local/` | Canonical git-ignored machine-local bookkeeping: the worktree scope registry and parallel work log. |
| `.agents/agents/` | Reserved for future provider-neutral subagent definitions; currently empty. |
| `.agents/hooks/` | Reserved for provider-neutral hook scripts; currently empty. |
| `.codex/`, `.cursor/` | Thin provider pointers back to this file. |

Application source directories (`App/`, `Core/`, `Platform/`, `Tests/`) are
**planned**; see [`conventions.md`](.agents/context/dev-spec/conventions.md).

## Development Specification

| Topic | File |
|-------|------|
| Stack, layout, and build/test commands | [`.agents/context/dev-spec/conventions.md`](.agents/context/dev-spec/conventions.md) |
| Worktree workflow, build isolation, and the scope guard | [`.agents/context/dev-spec/worktree-workflow.md`](.agents/context/dev-spec/worktree-workflow.md) |
| Git workflow and branch naming | [`.agents/context/dev-spec/git-workflow.md`](.agents/context/dev-spec/git-workflow.md) |
| Prerequisites and setup | [`.agents/context/dev-spec/prerequisites.md`](.agents/context/dev-spec/prerequisites.md) |

## Product Context

| Topic | File |
|-------|------|
| What doppelganger is for and who uses it | [`.agents/context/product/product-vision.md`](.agents/context/product/product-vision.md) |
| Domain model, vocabulary, and the verification contract | [`.agents/context/product/offload-model.md`](.agents/context/product/offload-model.md) |

## Skills

This registry lists every shared skill in `.agents/skills/`. Update it in the
same approved change whenever a skill is added, removed, or renamed. A skill may
be low-freedom and deterministic or judgment-driven; its `SKILL.md` defines that
execution style without creating a separate command type.

| Skill | Summary |
|-------|---------|
| [`new-worktree`](.agents/skills/new-worktree/SKILL.md) | Create and configure a confirmed, scope-registered worktree from fresh `origin/main`. |
| [`work-in-worktree`](.agents/skills/work-in-worktree/SKILL.md) | Route work to the scope-matching worktree or define a new one. |
| [`list-all-worktrees`](.agents/skills/list-all-worktrees/SKILL.md) | Number every worktree with dirty state, main deltas, live PR status, and deletion readiness. |
| [`update-worktrees`](.agents/skills/update-worktrees/SKILL.md) | Preflight and safely merge a remote base branch into eligible worktrees. |
| [`delete-worktree`](.agents/skills/delete-worktree/SKILL.md) | Retire selected worktrees safely while preserving their branches. |
| [`new-branch`](.agents/skills/new-branch/SKILL.md) | Commit approved work, sync remote `main`, and create a confirmed convention-named branch. |
| [`resolve-conflicts`](.agents/skills/resolve-conflicts/SKILL.md) | Diagnose, group, resolve, and verify Git conflicts without committing. |
| [`draft-pr`](.agents/skills/draft-pr/SKILL.md) | Draft a PR and, after approval, create it and update local worktree memory. |
| [`open-pr`](.agents/skills/open-pr/SKILL.md) | Promote or create a PR that is ready for review, subject to approval. |
| [`commit`](.agents/skills/commit/SKILL.md) | Stage and commit current changes after explicit approval, with a Conventional Commits message composed from the diff. |
| [`grill-me`](.agents/skills/grill-me/SKILL.md) | Stress-test a plan or design through focused, dependency-aware questions. |

Build- and run-oriented skills will be added once application source exists.

## Provider Discovery

- **Codex** — reads this `AGENTS.md` and discovers repository skills in
  `.agents/skills/`. `.codex/` holds only a pointer.
- **Claude** — reads `CLAUDE.md`, which imports this file. Shared workflows stay
  in `.agents/`; no Claude-specific skill or command adapters are tracked.
- **Cursor** — reads this root `AGENTS.md`; `.cursor/rules/` holds only an
  always-applied pointer.

## Quick Start

- [`README.md`](README.md) — repository overview and current status.
- [`prerequisites.md`](.agents/context/dev-spec/prerequisites.md) — toolchain setup.
- [`offload-model.md`](.agents/context/product/offload-model.md) — read this before
  touching anything that copies or verifies files.

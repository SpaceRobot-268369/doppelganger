# Worktree Workflow (parallel development)

doppelganger develops features in **parallel** using
[`git worktree`](https://git-scm.com/docs/git-worktree). Each unit of work gets
its own working directory *and* branch, so multiple features can be edited,
built, and reviewed at the same time without stashing or branch-switching.

> **This is the default workflow.** Use the traditional single-checkout,
> branch-switching flow (see [`git-workflow.md`](git-workflow.md)) only when the
> developer explicitly asks for it.

Branch **naming** is identical to the traditional flow — see
[`git-workflow.md`](git-workflow.md). This document covers everything specific to
worktrees: on-disk layout, folder naming, build isolation, the local bookkeeping
files, and the scope guard.

---

## 1. When to use which workflow

| Situation | Workflow |
|-----------|----------|
| Any normal feature/fix, especially alongside other in-flight work | **Worktree** (default) |
| Trying several approaches to compare results | **Worktree** — one per variant (see §4) |
| Developer explicitly asks for the old single-checkout flow | Branch-based ([`git-workflow.md`](git-workflow.md)) |
| Tiny throwaway edit with nothing else in flight | Worktree or a non-main branch. Never make tracked edits in `doppelganger-main/`. |

### Planning-to-execution routing

When the current working directory is `doppelganger-main/` and the developer asks
for parallel or independent work streams, the agent must call out that each
stream belongs in its own worktree before implementation.

If implementation is approved from a plan, the developer does not need to reset
the working directory manually. The agent must route each task to the matching
existing worktree, or create/confirm the required worktree before editing. The
main checkout may be used for planning, inspection, and the narrow canonical
local-bookkeeping exception defined in Principles 1 and 5; tracked feature/fix
edits must happen in a non-main branch/worktree.

### Worktree creation is separate from task execution

When a developer requests a new worktree and provides a short task description,
use that description only to propose the branch, folder, and recorded scope.
The developer's confirmation authorizes **only** creation/configuration of that
worktree: branch and directory creation, local build-isolation setup, and
canonical local-bookkeeping updates.

After reporting the created worktree, stop. Do not begin task analysis,
implementation, validation, building, or any other task work from that same
confirmation. Begin the actual task only after a **subsequent developer message**
explicitly asks to start it. This is a separate confirmation even when the task
description was supplied with the creation request.

---

## 2. On-disk layout

An umbrella folder named `doppelganger/` holds the main checkout and every
worktree side by side. The main checkout is `doppelganger-main/` (tracks `main`);
each worktree is a sibling directory named per §3:

```
/Users/lucas/Dev/Personal Project/doppelganger/   # umbrella folder (worktree parent)
├── doppelganger-main/                            # main checkout (main)
├── doppelganger-feat-xxhash-checksum/            # a worktree
├── doppelganger-fix-unmount-mid-copy/            # a worktree
└── doppelganger-docs-offload-model/              # a worktree
```

- `doppelganger-main/` is the main checkout — never turned into a worktree and
  never used to author tracked changes. It may cleanly fast-forward to
  `origin/main` under Principle 5. Its other write exception is the two canonical
  generated, git-ignored bookkeeping files in §6.
- The **umbrella** folder (the directory that *contains* `doppelganger-main/`) is
  the parent for all worktrees.
- Before creating the first worktree, confirm this layout. **If it is not as
  expected** (no `doppelganger-main/`, or the umbrella can't be determined),
  **stop and confirm with the developer** rather than guessing a location.
- **Never relocate a worktree or the main checkout by dragging in Finder or `mv`.**
  Git worktrees store absolute paths, so a raw move breaks the linkage. Use
  `git worktree move <src> <dst>` to relocate, and `git worktree repair` (run from
  the main checkout, passing the moved paths) to fix links after a move that
  already happened.

---

## 3. Worktree folder naming

Derive the folder name from the branch, flattened (no slashes), kebab-case:

```
doppelganger-<type>-<feature>
```

| Branch | Worktree folder |
|--------|-----------------|
| `feat/xxhash-streaming-checksum` | `doppelganger-feat-xxhash-streaming-checksum` |
| `fix/destination-unmount-mid-copy` | `doppelganger-fix-destination-unmount-mid-copy` |
| `docs/offload-model-vocabulary` | `doppelganger-docs-offload-model-vocabulary` |

If two branches would collapse to the same folder, keep enough of the branch to
disambiguate.

---

## 4. Experiment / variant sets

When the agent proposes several options and the developer says "implement all of
them so I can compare," create **one worktree per variant**, all sharing an
**experiment-group id**.

- Take the base branch stem and append `-v<N>-<label>`:

  ```
  feat/transfer-progress-v1-determinate
  feat/transfer-progress-v2-per-file
  feat/transfer-progress-v3-throughput
  ```

  Folders: `doppelganger-feat-transfer-progress-v1-determinate`, `…-v2-per-file`, …

- Record all variants under the same `experiment` id in `worktree-scopes.md` (§6)
  so they can be compared and the losers retired together via
  [`delete-worktree`](../../skills/delete-worktree/SKILL.md) once a winner is
  chosen.

---

## 5. Creating a worktree + branch (best practice)

Prefer the [`new-worktree`](../../skills/new-worktree/SKILL.md) skill, which
performs all of the steps below (naming, build isolation, bookkeeping) with the
required confirmations. The underlying git best practice is a **single command**
that creates the branch and the worktree together, based on fresh `origin/main`:

```bash
git fetch origin
git worktree add -b <branch-name> "<parent>/<folder-name>" origin/main
```

Notes:

- `-b <branch-name>` creates the branch **at add time** — do not pre-create it.
- Basing on `origin/main` (not local `main`) avoids inheriting an out-of-date
  local `main`.
- `git worktree add` does **not** require the current working tree to be clean —
  unlike branch-switching, it never disturbs your other worktrees.
- The main checkout must not currently have `<branch-name>` checked out; a branch
  can be checked out in only one worktree at a time.

---

## 6. Local bookkeeping files (git-ignored)

Two canonical per-user files live under
`<main-checkout>/.agents/memory/local/` (git-ignored). Agents must discover the
main checkout with `git worktree list --porcelain` and read/update that canonical
copy even when operating from a secondary worktree. Do not create independent
registry copies in each worktree.

On first use, create the local files from the tracked examples in the main
checkout:

```bash
cp .agents/memory/local/worktree-scopes.example.md \
  .agents/memory/local/worktree-scopes.md
cp .agents/memory/local/parallel-work-log.example.md \
  .agents/memory/local/parallel-work-log.md
```

They are the source of truth for **what each worktree is for** and **what you
learned while working in it** — essential when several stacks are in flight at
once.

### `worktree-scopes.md` — the scope registry

Keep active entries under `## Active worktrees` and retained history under
`## Retired worktrees`. Create/update an entry whenever a worktree is created,
its scope changes, or it is retired. Each entry records:

| Field | Meaning |
|-------|---------|
| **Folder** | Worktree directory name (`doppelganger-…`). |
| **Branch** | Full branch name. |
| **Scope** | The paths/areas this worktree is allowed to change (globs or prose). This is what the **scope guard** (§8) checks against. |
| **Bundle ID** | The worktree's build-isolation bundle identifier (§7). |
| **Experiment** | Experiment-group id, if part of a variant set (§4). |
| **PR** | PR number + URL, or `—` when no PR exists. |
| **PR Status** | `not opened`, `draft`, `open — awaiting review`, `changes requested`, `approved — awaiting merge`, `merged — retirement check pending` (active), `merged` (retired final state), or `closed/abandoned`. |
| **Status** | `active` or `retired`. A retired entry also records whether its directory was removed or already missing, that its branch was preserved, and the merge/PR outcome when applicable. |
| **Created** | Absolute date. |
| **Retired** | Absolute retirement date; present only for retired entries. |

`PR Status` does not replace the worktree lifecycle status. A worktree remains
`active` while its PR is draft/open, awaiting review, changes-requested, approved
but unmerged, or otherwise likely to need follow-up edits. A merged PR also does
not retire the worktree automatically: first refresh Git/PR state and check for
local changes, commits after merge, TODOs, and requested follow-up work. Only the
`delete-worktree` retirement flow changes Status to `retired`.

Whenever a PR-related skill creates or promotes a PR, it updates both canonical
local-memory files. Because reviews can change outside the agent, worktree
inventory and retirement flows should refresh the PR fields with GitHub when
available; a refresh failure is reported but must not invent a status.

### `parallel-work-log.md` — the running log

A running, per-worktree log of essential context so nothing is lost when
switching between parallel stacks: decisions made, gotchas hit, where you left
off, open TODOs, and cross-worktree dependencies. Append to the relevant
worktree's section as you work. On retirement, keep the section and append a
final closeout entry containing the retirement date, directory/stale-entry
result, preserved branch, merge/PR outcome, build cleanup decision, and any
remaining TODOs.

> The exact starter format is committed in `worktree-scopes.example.md` and
> `parallel-work-log.example.md`. The generated files are machine-local routine
> bookkeeping: they are not change-protected, must remain git-ignored, and must
> never be staged or committed.

---

## 7. Build isolation (the Xcode equivalent of per-worktree ports)

> **Status: planned.** There is no Xcode project yet to carry the configuration
> below. Adopt it when the project is created; until then, this section records
> the decision and the hazard.

Two things separate parallel worktrees, and only one of them is automatic:

**Already isolated — DerivedData.** Xcode keys DerivedData by project path, so
each worktree gets its own build products, index, and module cache for free. No
configuration needed.

**Not isolated — the bundle identifier.** Every worktree building
`com.lucastao.doppelganger` produces an app with the *same* identifier. The
consequences are quiet and confusing:

- macOS treats them as the same app for launch services; the last one built can
  win when you double-click.
- They share one `~/Library/Application Support/com.lucastao.doppelganger/`
  container and one `UserDefaults` domain, so a debug build from one worktree
  reads and overwrites another's saved destinations, bookmarks, and preferences.
- Security-scoped bookmarks resolved by one build appear in the other's state.

**The scheme:** each worktree builds with a suffixed identifier derived from its
folder slug:

```
com.lucastao.doppelganger.<worktree-slug>
```

For example `doppelganger-feat-xxhash-checksum` →
`com.lucastao.doppelganger.feat-xxhash-checksum`. The main checkout keeps the
base identifier `com.lucastao.doppelganger`.

Set it through a **git-ignored `Local.xcconfig`** at the worktree root, which the
project's build settings include:

```
PRODUCT_BUNDLE_IDENTIFIER = com.lucastao.doppelganger.feat-xxhash-checksum
```

`new-worktree` assigns the identifier and records it in the registry's
**Bundle ID** field — the slot where AUniverse records ports.

**Data isolation follows from the identifier.** Once each worktree has its own
bundle ID, each gets its own app-support container and defaults domain. Nothing
is shared, and each build starts from empty app state.

---

## 8. Scope guard (Principle 6)

Per **Principle 6** in [`AGENTS.md`](../../../AGENTS.md), before modifying any
tracked file the agent checks the active worktree's **Scope** in the canonical
main-checkout `worktree-scopes.md`:

- **Match** → proceed.
- **Out of scope** → **stop before editing** and ask the developer to either
  (a) expand the recorded scope for this worktree, or (b) move the work to a
  new/other worktree.
- **Canonical files missing** in a doppelganger worktree layout → initialize them
  from the tracked examples before routing or creating worktrees.
- **No entry for a non-main location** after that check (for example, a
  traditional branch-based checkout or fresh clone with no registry) → the guard
  is **passive**; proceed normally. `main`/`doppelganger-main/` remains read-only
  for authored tracked edits under Principle 5; clean fast-forward
  synchronization with `origin/main` remains allowed.

This is what keeps parallel features isolated on dedicated worktrees/branches.

---

## 9. Retirement

Use the [`delete-worktree`](../../skills/delete-worktree/SKILL.md) skill when a
worktree is merged, abandoned, stale, or otherwise no longer needed. It checks
dirty state and unresolved notes, handles installed-build cleanup approval,
removes the selected worktree directory, prunes stale Git metadata, and updates
local memory.

Retirement always follows these rules:

- Never remove `doppelganger-main/`.
- Never delete the worktree's branch; preserve and report it.
- Never force-remove dirty or untracked work without explicit confirmation after
  showing the status.
- Move the registry entry from `## Active worktrees` to `## Retired worktrees`;
  keep Branch, Scope, Bundle ID, Experiment, PR, PR Status, and Created; set
  Status to `retired`; add the retirement outcome and `Retired` date.
- Keep the work-log section and append the standard retirement closeout entry.

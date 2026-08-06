---
name: resolve-conflicts
description: Diagnose, group, resolve, and verify Git conflicts from merges, rebases, cherry-picks, or stash operations without committing. Use when an operation hits conflicts or the user asks to resolve or fix a merge conflict.
---

# Skill: resolve-conflicts

Diagnose and resolve git conflicts (merge, rebase, cherry-pick, stash-pop) in
this repo. First produce a grouped, reasoned report of every conflicted file —
clustering files that conflict for the same reason — then auto-resolve trivial
conflicts and pause for the developer on complex ones, defaulting to `main`'s
side unless told otherwise. Invoke when an operation hits conflicts or the user
says "resolve conflicts" / "fix the merge".

This is a **skill**: the agent reasons about intent and chooses resolutions. It
operates within the Principles in `AGENTS.md`.

## Purpose

Turn a wall of conflict markers into a **grouped, reasoned report** the developer
can act on, then resolve them safely. The flow is always: diagnose → report →
resolve → verify → hand back.

Resolution conventions follow:
- [`git-workflow.md`](../../context/dev-spec/git-workflow.md) — branch/commit rules.
- [`AGENTS.md`](../../../AGENTS.md) — Principles, repo map, and the skill registry
  (single-source-of-truth rules).

This skill resolves and stages conflicts. Continuing a merge, rebase, or
cherry-pick may create commits, so completion is a separate explicit approval
gate in Step 8. This skill never pushes.

---

## Prerequisites

> Requires an in-flight git operation with conflicts (merge/rebase/cherry-pick/
> stash), and — for the Step 7 sanity checks — a working Xcode toolchain once
> application source exists. If a needed tool is missing, tell the dev and guide
> setup via
> [`../../context/dev-spec/prerequisites.md`](../../context/dev-spec/prerequisites.md).

## Hard guardrails

- **Report before touching anything.** Always present the grouped report and get
  the developer's read on the complex groups before editing files.
- **Default side = `main`.** When a conflict isn't trivial and the developer
  hasn't weighed in, prefer the version coming from `main` (the side being
  merged/rebased onto) — but surface the choice and ask first. Never silently
  pick a side on a complex conflict.
- **Never** `git checkout --ours <path>` / `--theirs <path>` wholesale on a file
  to "make it go away" without understanding both sides.
- **Never** `git merge --abort` / `git rebase --abort` without explicit
  confirmation — it discards in-progress resolution work.
- **Never** use `--no-verify`, never `--force`, never rewrite shared history
  (Principle 4), and never resolve a delete/modify conflict by blind deletion
  without confirming intent.
- **Agent files are change-protected (Principle 1).** Conflicts in `AGENTS.md`,
  `CLAUDE.md`, `.agents/**`, or tracked provider configuration are **always
  complex** and **require explicit user approval** — never auto-resolve them. See
  the special-case note in Step 3.
- **Ours/theirs is swapped during rebase / cherry-pick.** In a *merge*,
  `--ours` = your branch, `--theirs` = incoming (main). In a *rebase*, HEAD is
  main's replayed-onto base, so `--ours` = main and `--theirs` = your commits.
  Always confirm direction from Step 1 before reasoning about sides.
- Resolved files must contain **zero** conflict markers before completing the
  operation.

---

## Pipeline

### Step 1 — Detect context

```bash
git status                           # shows operation + unmerged paths
git rev-parse --abbrev-ref HEAD      # current branch
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  path="$(git rev-parse --git-path "$marker")"
  test -e "$path" && printf '%s\n' "$path"
done
```

Determine which operation is in flight — **merge**, **rebase**, **cherry-pick**,
or **stash pop** — and therefore which side is "ours" vs "theirs" (see guardrail
above). State this explicitly before going further.

### Step 2 — Inventory

```bash
git diff --name-only --diff-filter=U     # all conflicted paths
git diff --diff-filter=U --stat          # rough size of each conflict
```

Capture the full conflicted set. Note conflict *types* from `git status`:
"both modified", "deleted by them / us", "added by both".

### Step 3 — Diagnose each file

For every conflicted path, read the conflicted hunks and work out **what change
each side was making** that caused the collision — the *intent*, not just "both
changed it". Use `git log` if the diff alone doesn't reveal it:

```bash
git log --oneline -3 main -- <path>           # what main was doing here
git log --oneline -3 HEAD..<branch> -- <path> # what this branch was doing here
```

For each file (or group) capture three things:
1. **Conflicting changes** — what main's change does vs what the branch's change
   does, and why they overlap.
2. **If you keep main** — the concrete consequence for the branch's work.
3. **If you keep branch** — the concrete consequence for main's work.

A conflict is **trivial** only when one side fully subsumes the other (pure
formatting, or main's rename with no real branch logic on top) so neither
consequence loses real work. Otherwise it's **complex**.

Special-cased files in this repo:
- **Agent files — `AGENTS.md`, `CLAUDE.md`, `.agents/**`, and tracked provider
  configuration** — always **complex**; require user approval (Principle 1).
  These are typically *additive*: the repo map, dev-spec index, and skill
  registry must keep **both sides'** true entries, not one side. Merge the union
  of real entries; never drop a legitimate skill or principle from either side.
- **`Doppelganger.xcodeproj/project.pbxproj`** — machine-generated and
  conflict-prone when both sides add files. Never hand-merge it blind: prefer
  taking one side whole and re-adding the other side's files through Xcode, then
  verify the project opens and both targets still build.
- **`.agents/memory/local/*.md`** — git-ignored; these should never appear as
  conflicts. If they do, something was committed that should not have been —
  stop and report rather than resolving.

### Step 4 — Group

Cluster files that conflict for the **same reason** into one group. Single-cause
files stand alone. Tag each group **trivial** (auto-resolvable) or **complex**
(needs a decision). Any group containing an agent file is complex by rule.

### Step 5 — Present the report

Show this table **before editing anything**:

| Group | Files | Conflicting changes (main vs branch) | If keep main | If keep branch | Recommendation | Class |
|---|---|---|---|---|---|---|
| 1 | `ChecksumTests.swift` | main renamed `hash`→`digest`; branch only reformatted callers | branch reformatting dropped (cosmetic) | rename undone, calls break | adopt main + reapply formatting | trivial |
| 2 | `OffloadEngine.swift` | main reworked the verify pass; branch added retry on the old path | retry feature lost | rework reverted | **needs your call** | complex |

- **Trivial** rows: state the resolution you'll auto-apply.
- **Complex** rows: state the default (main's side) and **what keeping it costs
  the branch**, then ask the developer before applying.

### Step 6 — Resolve

- **Trivial groups** — auto-resolve, then `git add` each path.
- **Complex groups** — apply only the resolution the developer confirmed (default
  main's side if they defer). Hand-edit the hunks; never wholesale `--ours`/
  `--theirs` unless the developer explicitly chooses an entire side.
- **Agent files** — only after explicit approval; keep the union of true entries.

### Step 7 — Verify

```bash
git diff --check                         # no leftover markers / whitespace errors
grep -rn '^<<<<<<<\|^=======\|^>>>>>>>' <resolved paths>   # belt-and-suspenders
git diff --name-only --diff-filter=U     # must be empty
```

Run the relevant sanity check for what was touched. Once application source
exists, that is the build and test pair from
[`conventions.md`](../../context/dev-spec/conventions.md):

```bash
xcodebuild -scheme Doppelganger -destination 'platform=macOS' build
xcodebuild test -scheme Doppelganger -destination 'platform=macOS'
```

For a docs- or agent-files-only resolution, verify that every relative link still
resolves instead.

### Step 8 — Stage, preview, and complete only after approval

Stage the resolved paths, then show the developer:

- staged paths and validation results;
- the in-flight operation;
- the exact continuation command;
- that continuing may create or replay one or more commits.

Do not continue yet:

```bash
git add <resolved paths>
```

For a stash pop, staging completes the resolution; there is no continuation
command and no commit is created by this skill.

For merge, rebase, or cherry-pick, wait for explicit developer approval of the
displayed continuation action. On approval, run exactly the applicable command:

```bash
git merge --continue        # or: git rebase --continue
                            #     git cherry-pick --continue
```

Report every resulting commit hash. If continuation stops on another conflict,
return to Step 1 and require a new preview/approval before the next continuation.

Then stop. Report:
- Operation + branch.
- Groups resolved, how, and which side won each.
- Whether the operation remains staged/in progress or was explicitly continued.
- Resulting commit hashes, if continuation was approved.
- Anything left for the developer (deferred decisions, sanity-check results).

---

## Out of scope

- New standalone commits and all pushes → [`commit`](../commit/SKILL.md) skill +
  the developer.
- Deciding *whether* to merge or rebase in the first place.
- Auto-`abort` of any operation — only on explicit request.
- Branch creation / renaming.

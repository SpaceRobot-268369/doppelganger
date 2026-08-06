# Git Workflow & Branch Naming

## Two workflows

- **Worktree (default).** Each unit of work gets its own directory *and* branch,
  so features develop in parallel. See
  [`worktree-workflow.md`](worktree-workflow.md) — and use the
  [`new-worktree`](../../skills/new-worktree/SKILL.md) skill.
- **Branch-based (traditional).** A single checkout that switches branches. Use
  this only when the developer explicitly asks for it; the
  [`new-branch`](../../skills/new-branch/SKILL.md) skill and the
  [Workflow](#workflow) section below cover it.

Branch **naming** (below) is the same for both.

## Branches

`main` is the integration branch. Feature work happens on a branch named:

```
<type>/<short-kebab-description>
```

`<type>` matches the Conventional Commits type that best describes the work:
`feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `perf`, `build`, `ci`.

Examples:

```
feat/xxhash-streaming-checksum
fix/destination-unmount-mid-copy
docs/offload-model-vocabulary
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<optional body — what & why, wrapped ~72 cols>

<optional co-author trailer>
```

- **subject** — imperative, lowercase, no trailing period.
- **scope** — optional, the area touched (`core`, `ui`, `platform`,
  `agent-files`).
- **co-author trailer** — attribute the agent that actually made the commit, when
  its standard name and email identity are known. Never guess an address or
  attribute work to a different provider; omit the trailer otherwise.

Use the [`commit`](../../skills/commit/SKILL.md) skill rather than composing
commits ad hoc.

## Approval gates

Per [Principle 4](../../../AGENTS.md#principles):

- **Never commit without explicit user approval.** Show the staged file list and
  the proposed message first.
- **Never push as part of committing.** Pushing is a separate action requiring
  its own approval.
- **Never `--force` push** and never rewrite shared history.

## Agent files

Per [Principle 1](../../../AGENTS.md#principles), changes to `AGENTS.md`,
`CLAUDE.md`, tracked `.agents/` content, and provider adapters must be proposed
and approved before they are written — including in commits that are otherwise
routine. Scope them to their own commit with the `agent-files` scope where
practical.

## Workflow

> This is the **branch-based (traditional)** flow. For the default worktree flow
> see [`worktree-workflow.md`](worktree-workflow.md). Do not use this flow inside
> `doppelganger-main/`; that checkout may synchronize with remote main but may
> not become an implementation checkout (Principle 5).

1. Start from the latest main:
   `git checkout main && git fetch origin && git pull --ff-only origin main`
2. Create your branch following the syntax above. Push with `-u` only after
   explicit developer approval.
3. Develop and test locally; create each commit through the approval-gated
   [`commit`](../../skills/commit/SKILL.md) skill.
4. Before merging, fetch `origin/main`, preflight the update, and use the
   approval-gated synchronization in
   [`draft-pr`](../../skills/draft-pr/SKILL.md) or
   [`update-worktrees`](../../skills/update-worktrees/SKILL.md) if the branch is
   behind. Resolve predicted conflicts separately with
   [`resolve-conflicts`](../../skills/resolve-conflicts/SKILL.md).
   **Never `--force`** onto shared history.
5. Open a Pull Request and wait for review —
   [`draft-pr`](../../skills/draft-pr/SKILL.md) then
   [`open-pr`](../../skills/open-pr/SKILL.md).

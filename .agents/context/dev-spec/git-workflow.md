# Git Workflow

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

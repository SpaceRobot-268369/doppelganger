# Agent Memory (local)

Per-user, **git-ignored** agent memory — notes local to one machine that must
never be committed.

## The two canonical files

| File | Purpose |
|------|---------|
| `worktree-scopes.md` | The worktree scope registry — what each worktree may change, its bundle ID, PR state, and lifecycle status. |
| `parallel-work-log.md` | The running per-worktree log — decisions, gotchas, where you left off, open TODOs. |

Both are generated from the tracked `*.example.md` templates beside this file:

```bash
cp worktree-scopes.example.md worktree-scopes.md
cp parallel-work-log.example.md parallel-work-log.md
```

**Keep exactly one copy of each, in the main checkout** (`doppelganger-main/`).
Secondary worktrees discover it with `git worktree list --porcelain` and read and
update that canonical copy — never an independent per-worktree registry.

Format spec:
[`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md).

## Ignore rules

`.gitignore` ignores `*.md` in this folder while keeping this README and the
`*.example.md` templates tracked. If you add a new local-memory file, commit a
matching `*.example.md` template so its format is shared even though its contents
are not.

For notes everyone on the repo should see, use [`../shared/`](../shared/) instead.

# Agent Memory (local)

Per-user, **git-ignored** agent memory — notes local to one machine that must
never be committed.

`.gitignore` ignores `*.md` in this folder while keeping this README and any
`*.example.md` templates tracked. If you add a new local-memory file, commit a
matching `*.example.md` template so its format is shared even though its contents
are not.

For notes everyone on the repo should see, use [`../shared/`](../shared/) instead.

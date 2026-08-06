# Worktree Scope Registry (local, git-ignored)

Canonical per-user registry for what every attached local worktree may change
and which build identity it uses. Keep the generated `worktree-scopes.md` in the
main checkout only; do not commit it or create independent copies per worktree.

Format spec: [`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md).

---

## Active worktrees

<!-- Copy this block once for each worktree. -->

<!--
### <worktree-folder-name>
- **Branch:** `type/feature`
- **Scope:** `path/to/allowed/area/**`
- **Bundle ID:** com.lucastao.doppelganger.<worktree-slug>
- **Experiment:** —
- **PR:** —
- **PR Status:** not opened
- **Status:** active
- **Created:** YYYY-MM-DD
-->

## Retired worktrees

Move an entry here when its worktree is retired. Keep its original branch,
scope, bundle ID, experiment, and creation date for history. Do not delete the
branch as part of worktree retirement.

<!--
### <worktree-folder-name> — RETIRED
- **Branch:** `type/feature` (preserved)
- **Scope:** `path/to/allowed/area/**`
- **Bundle ID:** com.lucastao.doppelganger.<worktree-slug>
- **Experiment:** —
- **PR:** [#123](https://github.com/<org>/<repo>/pull/123)
- **PR Status:** merged
- **Status:** retired — <worktree directory removed | stale registry entry retired>; branch preserved; <merge/PR outcome if applicable>
- **Created:** YYYY-MM-DD
- **Retired:** YYYY-MM-DD
-->

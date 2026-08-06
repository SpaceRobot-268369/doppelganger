# Parallel Work Log (local, git-ignored)

Canonical per-user running log for decisions, gotchas, current state, open TODOs,
and cross-worktree dependencies. Keep the generated `parallel-work-log.md` in
the main checkout only; do not commit it or create independent copies per
worktree.

Format spec: [`worktree-workflow.md` §6](../../context/dev-spec/worktree-workflow.md).

---

<!-- Copy this block once for each worktree. -->

<!--
## doppelganger-<type>-<feature> (branch: type/feature)

- YYYY-MM-DD — <decision, gotcha, current state, or TODO>
- YYYY-MM-DD — PR #<number> status: <draft | open — awaiting review | changes
  requested | approved — awaiting merge | merged — retirement check pending>.
  <review decision, required follow-up, or no additional notes>
-->

## Retirement closeout

When retiring a worktree, keep its existing section and append one final entry
using this format:

<!--
- YYYY-MM-DD — **Retired.** <real worktree directory removed | stale registry
  entry retired>. Preserved branch `type/feature`. Merge/PR outcome: <outcome or
  not applicable>. Build cleanup: <decision and result>. Remaining TODOs: <items
  or none>.
-->

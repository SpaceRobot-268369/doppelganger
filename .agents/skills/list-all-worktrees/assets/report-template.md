# Worktree Inventory Report

Use this structure for every `list-all-worktrees` response. Replace all
placeholders, omit optional detail lines that add no information, and never omit
a real worktree from the numbered table because a secondary status source is
unavailable.

## Worktrees

| # | Current | Worktree | Branch | HEAD | Dirty | vs local main | vs origin/main | PR | Build | Delete readiness |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `->` | `<folder>` | `<branch-or-detached>` | `<short-sha>` | `<clean-or-counts>` | `<ahead N / behind M>` | `<ahead N / behind M>` | `<live-or-recorded-status>` | `<none/installed/running/unverified>` | `<classification — reasons>` |

## Details

1. **`<folder>`**
   - Path: `<absolute-path>`
   - Scope: `<concise-scope-or-unavailable>`
   - Bundle ID: `<identifier-or-unavailable>`
   - Last commit: `<short-sha> <YYYY-MM-DD> <subject>`
   - Dirty: `<clean-or-staged/unstaged/untracked/conflict-counts>`
   - PR: `<number, lifecycle status, review status, and URL when available>`
   - Build: `<installed/running state for the bundle identifier>`
   - Readiness: `<READY / READY AFTER CLEANUP / NOT READY / REVIEW REQUIRED / NOT DELETABLE — MAIN>` — `<every blocker or uncertainty>`

Repeat the numbered detail block only for rows where it communicates scope,
blockers, uncertainties, stale-registry information, or other facts that do not
fit clearly in the table.

## Verification

- Local main: `<short-sha>` (`<verification state>`)
- Origin main: `<short-sha>` (`<fresh/stale/unavailable>`)
- Remote refs: `<verified/unverified — reason>`
- PR state: `<verified/unverified — reason>`
- Build state: `<verified/unverified — reason>`
- Local memory: `<verified/unverified — reason>`
- Safest deletion candidates: `<numbered rows and names, or none>`
- Changes made: none — no worktree, branch, commit, build, or memory file was changed.

## Rendering Rules

- Keep table and detail numbering identical and stable within the response.
- Use `->` only for the worktree containing the current working directory.
- Render comparisons exactly as `ahead N / behind M`; use `unavailable` instead
  of guessed counts.
- Render dirty counts as
  `staged N · unstaged N · untracked N · conflicts N`, omitting zero categories.
- Include the PR URL when a live or recorded PR exists.
- Put the readiness label first, followed by every blocker or uncertainty.
- Label stale registry entries clearly; do not present them as real worktrees.
- If any source is stale or unavailable, say so both in the affected field and
  in **Verification**.

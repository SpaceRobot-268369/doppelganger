# doppelganger

A macOS media-offload app: copy footage off camera cards to one or more
destinations, verify every byte with checksums, and write a transfer manifest —
in the mold of Hedge and Offshoot.

## Status

**Pre-implementation.** This repository currently contains the agent file system
and documentation only. There is no application source yet.

Planned stack: Swift + SwiftUI, macOS-only, Xcode project built with `xcodebuild`.

## Layout

Development happens in parallel Git worktrees. An umbrella folder holds the main
checkout and every worktree side by side:

```
doppelganger/                          # umbrella folder
├── doppelganger-main/                 # main checkout — read-only for tracked edits
└── doppelganger-<type>-<feature>/     # one worktree per unit of work
```

See [`worktree-workflow.md`](.agents/context/dev-spec/worktree-workflow.md).

## Working in this repo

[`AGENTS.md`](AGENTS.md) is the authoritative instruction file for every AI coding
agent, and the fastest orientation for humans too. The shared knowledge base lives
under [`.agents/`](.agents/):

- [`.agents/context/dev-spec/`](.agents/context/dev-spec/) — stack, conventions,
  worktree and git workflow, prerequisites.
- [`.agents/context/product/`](.agents/context/product/) — what the product does
  and the domain vocabulary it uses.
- [`.agents/skills/`](.agents/skills/) — reusable agent workflows.

`CLAUDE.md`, `.codex/`, and `.cursor/` are thin adapters that defer to `AGENTS.md`.

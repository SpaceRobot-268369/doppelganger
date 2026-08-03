# doppelganger

A macOS media-offload app: copy footage off camera cards to one or more
destinations, verify every byte with checksums, and write a transfer manifest —
in the mold of Hedge and Offshoot.

## Status

**Pre-implementation.** This repository currently contains the agent file system
and documentation only. There is no application source yet.

Planned stack: Swift + SwiftUI, macOS-only, Xcode project built with `xcodebuild`.

## Working in this repo

[`AGENTS.md`](AGENTS.md) is the authoritative instruction file for every AI coding
agent, and the fastest orientation for humans too. The shared knowledge base lives
under [`.agents/`](.agents/):

- [`.agents/context/dev-spec/`](.agents/context/dev-spec/) — stack, conventions,
  git workflow, prerequisites.
- [`.agents/context/product/`](.agents/context/product/) — what the product does
  and the domain vocabulary it uses.
- [`.agents/skills/`](.agents/skills/) — reusable agent workflows.

`CLAUDE.md`, `.codex/`, and `.cursor/` are thin adapters that defer to `AGENTS.md`.

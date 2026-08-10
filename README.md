# doppelganger

A macOS media-offload app: copy footage off camera cards to one or more
destinations, verify every byte with checksums, and write a transfer manifest —
in the mold of Hedge and Offshoot.

## Status

**Full-product 1.0 development.** The repository contains a native SwiftUI macOS
app, a bounded-memory copy-and-verify engine, JSON/Markdown/MHL evidence,
multi-task queueing, preflight safety review, interruption recovery, and
automated tests. The selected complete-product feature register is implemented;
hardware-matrix QA, signing, notarization, and distribution validation remain
before a public 1.0 release.

The product is deliberately conservative: it never deletes or formats source media,
requires a new output folder for each offload, and reports success only after
every requested copy passes read-back checksum verification and the required
evidence files are written.

Stack: Swift 6 + SwiftUI, macOS 26+, built with `xcodebuild`.

The 1.0 product is GPL-3.0-only, local-first, non-sandboxed direct distribution.
It has no account, trial, paid license state, telemetry, or cloud dependency.
See the [stable feature register](.agents/context/product/features.md) and
[delivery roadmap](.agents/context/product/roadmap.md).

## Run locally

Install Xcode 26 or newer, open `Doppelganger.xcodeproj`, select the
`Doppelganger` scheme and **My Mac**, then press **Run** (`⌘R`). Swift package
dependencies resolve automatically on the first build.

From a shell in the repository:

```bash
xcodebuild -project doppelganger.xcodeproj \
  -scheme Doppelganger \
  -destination 'platform=macOS' \
  build
```

The built app appears in Xcode's DerivedData products directory. The first
launch opens onboarding; its demo workflow creates synthetic app-owned files
only and never touches real camera media.

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
  and the domain vocabulary and visual language it uses.
- [`.agents/skills/`](.agents/skills/) — reusable agent workflows.

`CLAUDE.md`, `.codex/`, and `.cursor/` are thin adapters that defer to `AGENTS.md`.

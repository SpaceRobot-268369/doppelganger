# Contributing to Doppelganger

Thank you for helping build safer media offloads on macOS.

## Before changing code

- Read `AGENTS.md`, especially the source-media safety contract.
- Discuss substantial product or evidence-format changes before implementation.
- Never test copy, format, eject, cleanup, or deletion behavior against real
  cards or irreplaceable media. Use generated fixtures in a scratch directory.
- Keep source paths and bytes immutable. A failed verification must remain a
  failure and must never unlock destructive follow-up actions.

## Development

Requirements and build commands are documented in
`.agents/context/dev-spec/prerequisites.md` and
`.agents/context/dev-spec/conventions.md`.

Create a focused worktree, make the smallest coherent change, and run:

```sh
xcodebuild test \
  -project Doppelganger.xcodeproj \
  -scheme Doppelganger \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

New transfer behavior needs synthetic-fixture tests for success, cancellation,
I/O failure, evidence failure, and source immutability as applicable. UI text
should stay truthful about the distinction between copied, verification
pending, verified, and failed.

## Pull requests

- Explain the user-visible behavior and safety impact.
- List tests run and any known limitations.
- Keep unrelated formatting or refactors out of the change.
- Update numbered product features and evidence schemas when their contract
  changes; feature IDs are stable and never reused.

Contributions are licensed under GPL-3.0-only, the same license as the project.

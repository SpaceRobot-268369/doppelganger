# Conventions & Architecture

> **Status: planned, not implemented.** No application source exists in this
> repository yet. Every path, scheme, and target named below is a design
> decision to be created — do not cite them as existing code, and verify before
> referencing them.

---

## Stack

- **Swift 6**, strict concurrency enabled.
- **SwiftUI** for the interface; AppKit only where SwiftUI lacks the capability
  (e.g. certain Finder-adjacent affordances).
- **macOS only.** Minimum deployment target to be decided when the project is
  created; pick the oldest version that supports the concurrency and
  file-coordination APIs actually used.
- **Xcode project** (`Doppelganger.xcodeproj`), built with `xcodebuild`. Not an
  SPM-generated app target — local packages may still be vendored for isolated
  logic.

## Planned layout

```
Doppelganger.xcodeproj
App/            SwiftUI entry point, windows, views, view models
Core/           Offload engine, checksum, manifest writer — no UI, no AppKit
Platform/       macOS integration: DiskArbitration volume watching,
                security-scoped bookmarks, sandbox entitlements, disk I/O
Tests/          DoppelgangerTests — Core is the priority target for coverage
```

The dividing line that matters: **`Core/` must be independently testable with no
UI and no real hardware.** The offload engine takes abstractions over the file
system and volume discovery so tests can run against synthetic fixtures in a
scratch directory. Anything that talks to a real disk lives in `Platform/` behind
a protocol.

## Build & test commands

Build:

```bash
xcodebuild -scheme Doppelganger -destination 'platform=macOS' build
```

Run the full test suite:

```bash
xcodebuild test -scheme Doppelganger -destination 'platform=macOS'
```

Run a single test class or method:

```bash
xcodebuild test -scheme Doppelganger -destination 'platform=macOS' -only-testing:DoppelgangerTests/ChecksumTests
```

```bash
xcodebuild test -scheme Doppelganger -destination 'platform=macOS' -only-testing:DoppelgangerTests/ChecksumTests/testXXHash64MatchesReference
```

Pipe through `xcbeautify` or `xcpretty` if installed; neither is required.

## Conventions & gotchas

- **Swift API Design Guidelines** for naming. Types `UpperCamelCase`, members
  `lowerCamelCase`, no Hungarian prefixes.
- **`Core/` imports nothing from `App/` or `Platform/`.** Dependencies point
  inward. If `Core` needs the file system, it needs a protocol, not `FileManager`.
- **No force-unwrapping in file or I/O paths.** A dropped card, an unmounted
  volume, and a full destination are all *expected* runtime states, not
  programmer errors. Model them as typed failures.
- **Checksums stream.** Never load a media file into memory to hash it — camera
  files run to hundreds of gigabytes. Read in bounded chunks.
- **Progress reporting is derived, not authoritative.** A byte counter reaching
  100% is not success; only a completed verification pass is. See
  [`offload-model.md`](../product/offload-model.md).
- **Sandbox and entitlements.** Reading arbitrary volumes and remembering
  destinations across launches requires security-scoped bookmarks. Decide the
  sandbox posture before writing file-picking code, not after.
- **Don't test against real media.** Per
  [Principle 3](../../../AGENTS.md#principles), fixtures only.

## Tooling

- Formatting/linting: not yet adopted. If added, `swift-format` or SwiftLint with
  the config committed at the repo root, and the command documented here in the
  same approved change.
- CI: none yet. When added, pipelines live in `.github/workflows/` and this
  section records how to reproduce them locally.

# Conventions & Architecture

> **Status: active implementation.** The Xcode project, SwiftUI application,
> test target, transfer engine, and evidence writers exist. The product is in
> full 1.0 development and is not yet a signed production release.

---

## Stack

- **Swift 6**, strict concurrency enabled.
- **SwiftUI** for the interface; AppKit only where SwiftUI lacks the capability
  (e.g. certain Finder-adjacent affordances).
- **macOS 26+ only.** Liquid Glass is part of the intended product language.
- **Xcode project** (`Doppelganger.xcodeproj`), built with `xcodebuild`. Not an
  SPM-generated app target — local packages may still be vendored for isolated
  logic.
- **GRDB 7.x + SQLite** for the durable indexed catalog, migrations, and audit
  history. Portable evidence files remain independently readable.
- **AVFoundation plus pluggable format detectors** for media inspection. If a
  future build bundles FFmpeg/ffprobe, it must be LGPL-only, dynamically
  replaceable, and never required for core copying.

## Layout

```
Doppelganger.xcodeproj
App/            SwiftUI entry point, windows, views, view models
Core/           Offload engine, checksum, manifest writer — no UI, no AppKit
Platform/       macOS integration: volume watching, database setup, media tools,
                notifications, avatar storage, and disk I/O
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
- **Distribution is intentionally non-sandboxed.** Persistent paths are treated
  as hints and revalidated on use. File selection and drag/drop remain explicit;
  the app does not scan arbitrary user storage in the background.
- **Operator Profiles are not authentication.** Persist stable UUIDs, archive
  referenced profiles instead of deleting them, and snapshot the actor name in
  immutable attempts/audit events.
- **Don't test against real media.** Per
  [Principle 3](../../../AGENTS.md#principles), fixtures only.

## Tooling

- Formatting/linting: not yet adopted. If added, `swift-format` or SwiftLint with
  the config committed at the repo root, and the command documented here in the
  same approved change.
- GitHub Release CI is deliberately absent for 1.0. Release preparation uses a
  local, reviewed archive → Developer ID sign → hardened runtime → notarize →
  staple → DMG checklist.

## Data and evidence

- The Application Support catalog uses GRDB migrations, WAL, foreign keys, and
  transactional writes. Back up the database before a schema migration.
- Import schema-v1 spool manifests idempotently without moving or rewriting
  their evidence files.
- Task organization is mutable; attempts, audit events, item results, and
  evidence artifacts are append-only historical facts.
- Core JSON/Markdown/ASC MHL failure prevents Verified. Optional contact-sheet
  failure records an auxiliary warning without changing a verified media result.

## Localization

New user-facing text belongs in the localization resources. English is the
development language and Simplified Chinese (`zh-Hans`) is the required 1.0
localization; machine-readable JSON and MHL schema tokens remain invariant.

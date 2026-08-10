# Product Roadmap

doppelganger targets one complete public 1.0 release. The stages below are
internal dependency boundaries, not promises to publish incomplete product
tiers. Stable feature decisions live in [`features.md`](features.md).

## 1. Durable foundation

- Adopt GRDB/SQLite for projects, profiles, destinations, tasks, attempts,
  file results, evidence, health findings, and audit events.
- Import existing schema-v1 spool manifests idempotently without moving or
  rewriting evidence.
- Separate mutable task organization from immutable execution attempts.
- Upgrade the portable manifest to schema v2 while retaining v1 reads.

## 2. Transfer integrity and control

- Add verification profiles, the three approved checksums, safe pause/resume,
  digest-proven duplicate skipping, fine-grained retry, and standalone verify.
- Complete native ASC MHL generations, chain validation, source-MHL awareness,
  import, and Verify Again.
- Evolve the engine to bounded producer/independent-writer flow with truthful
  per-drive throughput and bottleneck reporting.

## 3. Workflow organization

- Add optional Projects and the Project → Shooting Day → Camera/Card history
  hierarchy while keeping No Project first-class.
- Add Destination Library, groups, roles, benchmarks, presets, naming tokens,
  multi-source batch review, manual queue controls, and cascading tasks.
- Support Finder drag-and-drop everywhere a source, destination, manifest, or
  avatar is selected. A drop may populate or review but never starts a task.

## 4. Media intelligence and evidence experience

- Add opt-in camera/card recognition, metadata inspection, health findings,
  prior-offload recognition, and explicit limited-support results.
- Keep media inspection pluggable and report limited metadata support
  explicitly. A future bundled FFmpeg/ffprobe adapter must satisfy the LGPL
  distribution conditions before it ships.
- Add optional JPEG contact sheets. Their failure is an auxiliary warning and
  never invalidates a successfully verified media copy.

## 5. Product readiness

- Add multiple local Operator Profiles, visible avatars, active-profile
  switching, immutable attribution snapshots, and append-only audit events.
- Add onboarding, permission diagnosis, a synthetic demo, in-app Help,
  English/Simplified Chinese localization, settings packages, diagnostics, and
  recovery tools.
- Finish GPL and third-party compliance, local signed/notarized DMG packaging,
  the hardware/test matrix, and the complete 1.0 acceptance pass.

## Non-goals for 1.0

No selective copy, media renaming/reorganization, auto-start queue rules,
source deletion/formatting, generic PDF/CSV/HTML reports, remote monitoring,
remote notifications, cloud destinations, NLE export, automation API/CLI/MCP,
or full accessibility certification.

# Features

The living feature register for doppelganger. It records the category baseline
set by Hedge/OffShoot, the product decision for doppelganger, and actual
development progress. Update it whenever a feature is accepted, deferred,
implemented, or materially changed.

This is a planning and progress document. The safety and correctness guarantees
for anything that copies or verifies media remain authoritative in
[`offload-model.md`](offload-model.md).

## Status legend

| Status | Meaning |
|---|---|
| `specified` | Defined in product documentation, but no implementation exists yet. |
| `planned` | Accepted for a future milestone; its detailed design may still be open. |
| `deferred` | Intentionally outside the current product scope. |
| `implemented` | Shipped and verified in the application. |
| `blocked` | Accepted, but waiting on a dependency or decision. |

## Current product features

| Feature | Priority | Status | Scope and acceptance bar |
|---|---:|---|---|
| Multi-destination offload | P0 | `specified` | Copy one read-only camera-card source to one or more destinations; every required destination must succeed. |
| Streaming checksum verification | P0 | `specified` | Hash the source while copying, then independently read back and hash each destination. A copied-but-unverified item is not successful. |
| Transfer manifest and logs | P0 | `specified` | Record each item's relative path, size, hash algorithm and digest, destination, timestamps, and result. Target MHL compatibility. |
| Honest result reporting | P0 | `specified` | Per-file, per-destination results; any required-destination failure fails the transfer. |
| Source and destination selection | P0 | `specified` | Choose source volumes/folders and destinations, and persist selections across launches. |
| Transfer progress | P0 | `specified` | Show preparation, copy, verification, and final result distinctly; never imply verification at the end of copying. |
| Interruption handling | P0 | `specified` | Handle unmounted sources/destinations, full disks, unreadable files, sleep, and checksum mismatches with a defined failed result and manifest. |
| Compatibility checksums | P1 | `specified` | Use xxHash64 by default; support MD5 when an MHL workflow or facility requires it. |
| Resume / retry | P1 | `planned` | Safely restart an interrupted transfer; incomplete or unverified destination files must be replaced and verified again. |
| Duplicate and collision handling | P1 | `planned` | Detect already-complete items and safely handle name, case-sensitivity, path-length, and filesystem conflicts. |
| Labels, naming, and destination templates | P1 | `planned` | Project/card labels, counters, dates, custom fields, and reproducible destination-folder rules. |
| Presets | P1 | `planned` | Save and share a complete offload configuration, including organization rules and verification policy. |
| Selective copy and organization | P1 | `planned` | Include/exclude patterns, safe empty-folder/bundle handling, flattening, renaming, and metadata-based sorting. |
| Queue and throughput policy | P1 | `planned` | Control concurrency and prioritize the fastest useful destination without compromising verification. |
| MHL re-verification | P2 | `planned` | Verify an existing MHL without a new copy; report missing files and hash mismatches. |
| Cascading transfers | P2 | `planned` | After a verified primary offload, create a separately tracked onward copy to another storage tier. |
| Remote transfer monitoring | P2 | `planned` | Read-only live progress and completion/failure notifications. |
| Automation API and scripts | P2 | `planned` | Emit explicit transfer lifecycle events with structured result data. |
| S3/object-storage destinations | P2 | `deferred` | Not part of the initial local-media-offload product. |
| Media browsing, playback, transcoding, proxies | P2 | `deferred` | These are separate workflow products, not evidence that an offload is safe. |
| Card formatting, source deletion, or moving source media | — | `deferred` | Not in the initial product. No source must be altered by an offload; see [Principle 3](../../../AGENTS.md#principles). |

## Hedge / OffShoot reference baseline

Hedge's current offload product is named **OffShoot**. The entries below are
reference capabilities, not commitments to ship every feature. They are grouped
to make comparison and prioritization straightforward.

| Area | Hedge / OffShoot capability | doppelganger decision |
|---|---|---|
| Transfer engine | Multiple sources and multiple destinations; simultaneous verified transfers from disks, folders, and mounted volumes. | P0 multi-destination local offload; multi-source batching can follow. |
| Verification | Transfer, source, and source-and-destination verification modes; XXH64BE by default; optional MD5, SHA-1, and C4; missing-file and zero-byte-media detection. | P0 source-to-destination read-back verification, xxHash64 and MD5; additional modes and legacy hashes later. |
| Evidence | Transfer Logs, MHL/ASC MHL support, automatic MHL checks, manual and batch MHL verification. | P0 manifest/logs and MHL target; MHL re-verification is P2. |
| Organization | Labels, custom elements, folder and filename formats, counters, timestamps, selective copying, bundle/folder exclusion, flattening, and presets. | P1. |
| Continuity | Duplicate detection; stop, resume, and retry behavior for interrupted, failed, or warning-bearing transfers. | P1, with the safety contract taking precedence over speed. |
| Scheduling | Queuing by source or destination, and cascading copies or destination groups. | Queue policy P1; cascading P2. |
| Connectivity | S3 destinations and browser-based remote monitoring with completion notifications. | Remote monitoring P2; object storage deferred. |
| Professional integrations | Ingest Browser, Codex/Alexa 35 workflows, scripts/API, floating licenses, and helper tooling. | Defer until a demonstrated user need; automation is P2. |

## Design decisions learned from the reference

- A green completion state must mean every required destination passed
  verification, not simply that all bytes were written.
- Source media remains read-only. doppelganger does not make a source safe to
  format; it tells the user precisely whether the requested copies verified.
- A transfer manifest is a deliverable, not diagnostic output. It must be
  sufficient for an independent later verification.
- Resume and duplicate detection are useful only if they cannot turn an
  incomplete or unverified destination file into an apparent success.
- Organization and cloud workflows are valuable, but cannot dilute the core
  copy → verify → manifest → report contract.

## Reference sources

Last reviewed: 2026-08-09.

- [OffShoot feature index](https://docs.hedge.video/offshoot/features)
- [OffShoot overview](https://docs.hedge.video/offshoot/overview)
- [Verification](https://docs.hedge.video/offshoot/features/verification)
- [Organization](https://docs.hedge.video/offshoot/features/organization)
- [Duplicate Detection](https://docs.hedge.video/offshoot/features/duplicate-detect)
- [Stop & Resume](https://docs.hedge.video/offshoot/features/stop-and-resume)
- [Standard vs. Pro feature matrix](https://docs.hedge.video/offshoot/standard-vs.-pro)

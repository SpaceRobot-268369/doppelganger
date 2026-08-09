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
| Multi-destination offload | P0 | `implemented` | One read-only source fans out directly to one or more destinations; every requested copy must verify. |
| Streaming checksum verification | P0 | `implemented` | Source hashing is bounded and shared across writers; every destination is independently read back uncached. |
| Transfer manifest and logs | P0 | `implemented` | JSON, Markdown, live/persistent logs, and MHL are written atomically. A failed run emits no partial MHL. |
| Honest result reporting | P0 | `implemented` | Per-file/per-destination results plus transfer-level evidence/source-plan issues; green is reserved for fully verified completion. |
| Source and destination selection | P0 | `implemented` | Native folder selection, drag/drop, recent locations, persisted drafts, exact new output-folder preview, and review preflight. |
| Transfer progress | P0 | `implemented` | Scanning, copying, verifying, evidence writing, and terminal verdicts are distinct; failed cards never display forced 100%. |
| Interruption handling | P0 | `implemented` | Typed unmount/full/read/source-change/checksum failures, sleep inhibition, atomic staging, quit warning, and relaunch recovery journal. |
| Compatibility checksums | P1 | `implemented` | xxHash64 default and MD5 compatibility are selectable per transfer and recorded in every evidence format. |
| Resume / retry | P1 | `planned` | Safe retry is implemented as a freshly reviewed new output folder that preserves the old incomplete folder. In-place whole-file resume remains future work. |
| Duplicate and collision handling | P1 | `planned` | Fresh output-root preflight and exclusive atomic publishing prevent overwrite. Verified duplicate skipping plus case/path-limit preflight remain future work. |
| Labels, naming, and destination templates | P1 | `planned` | Custom transfer/output-folder labels are implemented. Counters, custom fields, presets, and reusable templates remain future work. |
| Presets | P1 | `planned` | Save and share a complete offload configuration, including organization rules and verification policy. |
| Selective copy and organization | P1 | `planned` | Include/exclude patterns, safe empty-folder/bundle handling, flattening, renaming, and metadata-based sorting. |
| Queue and throughput policy | P1 | `planned` | Configurable concurrent queueing is resource-aware by physical volume. Adaptive destination prioritization remains future work. |
| Durable task history | P1 | `implemented` | Search/filter prior spool manifests, reveal JSON/Markdown evidence, and restore interrupted tasks as Needs Attention on relaunch. |
| Verified source eject | P1 | `implemented` | Offer eject only after a fully verified run and only when the selected source is the removable volume root. Never delete or format source media. |
| Project / shooting-day library | P1 | `planned` | Optional working context for new transfers plus Project → Shooting Day → Camera/Card organization and filtering of durable history. Unassigned transfers remain first-class. |
| Card identity / prior-offload detection | P1 | `planned` | Recognize previously seen media, show its verified destinations and evidence, and distinguish an unchanged card from changed contents. |
| Multi-source batch queue | P1 | `planned` | Review and enqueue several cards/sources together while preserving an independent plan, verdict, and evidence set for each transfer. |
| Camera-media health checks | P1 | `planned` | Report camera-folder structure, sidecars, split clips, image sequences, reel identifiers, timestamps, and suspicious missing or zero-byte media before starting. |
| MHL re-verification | P1 | `planned` | Import or select an existing ASC MHL, verify a folder or volume without a new copy, and report missing files and hash mismatches. |
| Handoff reports | P1 | `planned` | Export human-readable PDF, CSV, and HTML reports for a transfer, shooting day, or project while retaining links to machine-verifiable evidence. |
| Cascading transfers | P2 | `planned` | After a verified primary offload, create a separately tracked onward copy to another storage tier. |
| Remote transfer monitoring | P2 | `planned` | Read-only live progress and completion/failure notifications. |
| Automation API and scripts | P2 | `planned` | Emit explicit transfer lifecycle events with structured result data. |
| S3/object-storage destinations | P2 | `deferred` | Not part of the initial local-media-offload product. |
| Media browsing, playback, transcoding, proxies | P2 | `deferred` | These are separate workflow products, not evidence that an offload is safe. |
| Card formatting, source deletion, or moving source media | — | `deferred` | Not in the initial product. No source must be altered by an offload; see [Principle 3](../../../AGENTS.md#principles). |

## Accepted next-product roadmap

The following eight capabilities are accepted product direction after the MVP.
They are intentionally recorded as outcomes and safety boundaries rather than a
fixed implementation sequence. The MVP/demo may expose only the smallest useful
slice of each; later work can deepen them without changing their meaning.

### 1. Stop, resume, and verified duplicate detection

- A stopped, interrupted, or failed task can be reviewed and resumed without
  converting unverified data into apparent success.
- Resume is whole-file based for the initial implementation. A destination file
  may be skipped only when its final bytes independently match the expected
  digest; partial and staging files are removed or replaced and copied again.
- The source identity, destination plan, naming rules, and verification policy
  must still match. Any material change creates a newly reviewed plan instead of
  silently continuing an old one.
- A resume/retry produces a new evidence generation linked to the original task;
  it does not rewrite the original failure record.
- Duplicate detection explains where and when the prior verified copy was made
  and lets the operator review the decision instead of silently skipping work.

### 2. Presets and folder-naming templates

- A preset can capture destination roles, verification/checksum policy,
  organization rules, report behavior, and optional verified-source eject.
- Folder templates can use validated elements such as Project, Shooting Date,
  Unit, Camera, Card Label, and an incrementing counter.
- The New Offload review always renders the exact output path for every
  destination. Editing any template input invalidates the previous preflight.
- Presets are named, versioned, importable/exportable, and never conceal a
  safety-relevant change to the generated plan.

### 3. Card identity and already-offloaded detection

- Identify a card using available volume identity plus a deterministic content
  or plan fingerprint; do not rely on a user-editable volume name alone.
- When media is recognized, show the last verified time, destinations, transfer
  ID, and manifest/MHL links before the operator decides what to do.
- Clearly distinguish an unchanged card, a changed card, and a merely similar
  label. New, missing, or changed source files require a new transfer decision.
- Recognition never authorizes formatting, deletion, or mutation of source
  media.

### 4. ASC MHL and manual re-verification

- Import or drag an ASC MHL and verify a selected folder or mounted volume
  without performing another copy.
- Report missing, added, and hash-mismatched files separately; partial checking
  never yields a verified verdict.
- Re-verification is available from durable history as “Verify Again” and emits
  a new, timestamped evidence result linked to the original record.
- A compatible source MHL may accelerate planning only when its identity and
  file metadata match; destination bytes are still verified according to the
  selected policy.

### 5. Optional Project and Shooting Day library

- **Project is an optional working context, not a requirement to transfer.** The
  user can work in “No Project / All Transfers” or select a Project before
  creating tasks.
- A selected Project provides defaults and attaches new tasks to that context;
  switching projects never pauses, moves, or changes a running task.
- Durable history can be browsed and filtered as
  `Project → Shooting Day → Camera/Card → Transfer`, while a global All
  Transfers view always includes unassigned work.
- Existing transfers may be assigned or moved between Project/Shooting Day
  containers later. This edits organizational metadata only; original manifests
  and verification evidence remain immutable and traceable.
- Project and Shooting Day views can aggregate status, destination coverage,
  media totals, reports, and unresolved attention across their child transfers.

### 6. Multi-source batch queue

- Select several cards or source folders, then review the batch while retaining
  an independent label, preset, preflight, execution state, and evidence set for
  every source.
- Scheduling is resource-aware: independent physical volumes may run together,
  while contending sources/destinations queue predictably.
- Support an explicit review-all/start policy and optional eject per source only
  after that source has a fully verified terminal result.
- Batch completion never formats, clears, deletes, or moves source media.

### 7. Camera-media health checks

- Before starting, inspect recognized camera-folder structures, sidecars, split
  clips, image sequences, reel/card identifiers, and suspicious timestamp gaps.
- Summarize useful production metadata such as clip count, duration, frame size,
  and codec when it can be read without mutating the source.
- Findings are classified as blocking errors or reviewable warnings with clear
  reasons. Missing files, unreadable media, and invalid source/destination
  topology cannot be acknowledged away.
- Health findings become part of the transfer record so the handoff distinguishes
  source-media issues from copy or verification failures.

### 8. PDF, CSV, and HTML handoff reports

- Export reports for one transfer or aggregate them by Shooting Day and Project.
- Include project/day/camera/card context, source and destination volume identity,
  file/byte counts, timestamps, duration, average rate, verification policy,
  final verdict, app/OS version, and optional operator/company branding.
- Human-readable reports link back to the JSON manifest and ASC MHL rather than
  replacing machine-verifiable evidence.
- CSV supports production-office ingest; PDF and HTML prioritize readable,
  shareable handoff. Export failure cannot retroactively turn a failed evidence
  requirement into a verified transfer.

## Hedge / OffShoot reference baseline

Hedge's current offload product is named **OffShoot**. The entries below are
reference capabilities, not commitments to ship every feature. They are grouped
to make comparison and prioritization straightforward.

| Area | Hedge / OffShoot capability | doppelganger decision |
|---|---|---|
| Transfer engine | Multiple sources and multiple destinations; simultaneous verified transfers from disks, folders, and mounted volumes. | P0 multi-destination local offload; multi-source batching can follow. |
| Verification | Transfer, source, and source-and-destination verification modes; XXH64BE by default; optional MD5, SHA-1, and C4; missing-file and zero-byte-media detection. | P0 source-to-destination read-back verification, xxHash64 and MD5; additional modes and legacy hashes later. |
| Evidence | Transfer Logs, MHL/ASC MHL support, automatic MHL checks, manual and batch MHL verification. | P0 manifest/logs and MHL target; MHL re-verification is P1. |
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

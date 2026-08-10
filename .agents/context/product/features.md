# Feature Register

Stable, numbered product decisions for doppelganger. IDs never get reused. A
feature can move between milestones, but its meaning stays stable so product
discussion, code, tests, and release notes can refer to the same capability.
The correctness contract in [`offload-model.md`](offload-model.md) remains
authoritative whenever a feature affects copying, verification, or evidence.

## Status

| Status | Meaning |
|---|---|
| `implemented` | Present in the current application and covered by acceptance tests. |
| `accepted-1.0` | Required for the complete public 1.0 release. |
| `later` | Accepted after 1.0. |
| `parked` | Intentionally inactive with no scheduled milestone. |
| `not-planned` | Explicit product decision not to build this capability. |

## Product features

| ID | Feature | Status | Acceptance boundary |
|---|---|---|---|
| F01 | Pause and resume | `implemented` | Pause at a safe boundary; resume whole files in a new linked attempt without rewriting prior evidence. |
| F02 | Verified duplicate detection | `implemented` | Metadata finds candidates; only an independently matching digest permits a skip. |
| F03 | Fine-grained retry | `implemented` | Retry failed files or destinations in a new linked attempt. |
| F04 | Verification profiles | `implemented` | Fast, Standard, and Maximum have visibly different read policies and truthful terminal states. |
| F05 | Checksum selection | `implemented` | Settings-only single selection: XXH3-64 default, XXH64BE, or MD5; each task snapshots it. |
| F06 | Standalone verification | `implemented` | Verify existing media without copying and retain the result as an immutable attempt. |
| F07 | Full ASC MHL | `implemented` | Native Swift read/write, generations, chains, directory hashes, and conformance fixtures. |
| F08 | MHL import and Verify Again | `implemented` | Import/drag an ASC MHL and emit a new verification result for missing, added, or mismatched files. |
| F09 | Source MHL awareness | `implemented` | Reuse trusted source digests only when chain, schema, size, time, and source identity match. |
| F10 | Multi-source batch | `implemented` | Review and enqueue independent plans for several sources at once. |
| F11 | Manual queue controls | `implemented` | Reorder, prioritize, pause, resume, and cancel without hidden automatic rules. |
| F12 | Queue automation rules | `not-planned` | No watched folders, auto-add, or auto-start rules. |
| F13 | Cascading transfers | `implemented` | A verified destination can become a source for a separately evidenced onward task. |
| F14 | Destination groups | `implemented` | Named, reusable sets of destinations with explicit roles. |
| F15 | Presets | `implemented` | Versioned reusable transfer policy and output-plan configuration. |
| F16 | Folder naming templates | `implemented` | Validated project/day/camera/card/counter tokens with exact output previews. |
| F17 | Selective copy | `not-planned` | A transfer includes the complete reviewed source plan. |
| F18 | Flatten, rename, or reorganize media | `not-planned` | Relative source paths remain intact; only the enclosing task folder is templated. |
| F19 | Optional Project library | `implemented` | Tasks may use a Project or remain in No Project/All Transfers. |
| F20 | Shooting day, camera, and card organization | `implemented` | History groups without mutating immutable transfer evidence. |
| F21 | Card identity | `implemented` | Stable volume facts plus a deterministic source-plan fingerprint. |
| F22 | Already-offloaded warning | `implemented` | Show prior verified destinations and distinguish unchanged, changed, and merely similar cards. |
| F23 | Destination Library | `implemented` | Persist identity, role, capacity observations, benchmark, and verified history. |
| F24 | Advanced history | `implemented` | Search and filter task/attempt/evidence history by project, operator, media, state, date, or destination. |
| F25 | Durable database | `implemented` | GRDB/SQLite is the indexed catalog; evidence files remain portable source artifacts. |
| F26 | PDF, CSV, and HTML handoff reports | `later` | Human-readable aggregate reporting after 1.0. |
| F27 | Contact sheet | `implemented` | Optional post-verify JPEG; global default off plus manual generation; failure is an auxiliary warning. |
| F28 | Camera metadata analysis | `implemented` | Read useful production metadata without mutating media. |
| F29 | Media health checks | `implemented` | Detect structure, sidecar, sequence, split-clip, readability, zero-byte, and timestamp findings. |
| F30 | Camera format coverage | `implemented` | Pluggable detection for common ARRI, RED, Sony, Canon, Blackmagic, Codex, and audio-recorder layouts. |
| F31 | Live drive performance | `implemented` | Per-destination throughput, ETA, and bottleneck reporting. |
| F32 | Adaptive transfer pipeline | `implemented` | One bounded producer and independent destination writers; no unbounded buffering. |
| F33 | Destination benchmark | `implemented` | Manual, cached, disposable-file benchmark that never touches a source. |
| F34 | Automation API, CLI, and MCP | `later` | Explicit local automation surface; MCP is evaluated with the API design. |
| F35 | Remote monitoring | `parked` | Browser or phone progress is outside 1.0. |
| F36 | Remote notifications | `parked` | No Slack, email, or push; local macOS notifications remain. |
| F37 | Cloud destinations | `parked` | Local mounted storage only. |
| F38 | NLE metadata export | `parked` | No production metadata interchange in 1.0. |
| F39 | First-launch onboarding | `implemented` | Explain the workflow and establish the first local operator profile. |
| F40 | Permission guidance | `implemented` | Explain and diagnose macOS file-access permissions without claiming access the app lacks. |
| F41 | Sample/demo workflow | `implemented` | Create and offload synthetic temporary fixtures only. |
| F42 | In-app Help | `implemented` | Searchable workflow, status, safety, troubleshooting, and evidence guidance. |
| F43 | Localization | `implemented` | English and Simplified Chinese UI, errors, evidence labels, and Help. |
| F44 | Full accessibility completion | `parked` | Preserve current labels and Reduce Motion support; a complete audit is post-1.0. |
| F45 | Settings import/export | `implemented` | Versioned package for settings, presets, logical destinations, profiles, and avatar assets; never history/evidence. |
| F46 | Operator Profiles | `implemented` | Multiple local, non-authenticated profiles with avatars; attempts and state-changing audit events snapshot the selected operator. |

## Existing foundation

Implementation snapshot (2026-08-10): the complete selected 1.0 feature set
builds in Debug and Release, and the synthetic acceptance suite passes 93 tests
across transfer safety, evidence, database, media analysis, localization, and
workflow foundations. Hardware-matrix and signed/notarized distribution checks
remain release validation rather than product feature work.

The current application already demonstrates one-source-to-many-destinations,
bounded streaming hashes, uncached destination read-back, atomic staging, JSON,
Markdown and ASC MHL v2 evidence, resource-aware multi-task scheduling, durable
spool history, local notifications, interruption recovery, preflight checks,
and verified-source eject. These are the foundation for the accepted 1.0 work,
not a separate MVP product tier.

## Release decisions

- Open source under `GPL-3.0-only`; no trial, license, purchase restore, account,
  paid update channel, or telemetry.
- Direct distribution is a non-sandboxed, Developer ID signed, hardened,
  notarized and stapled DMG.
- GitHub Release CI and an automatic updater are not part of 1.0. A documented
  local release flow is required.
- Bundled FFmpeg must be an LGPL-only dynamic build with complete notices,
  reproducible build instructions, corresponding source, and replaceable
  libraries.

## Reference sources

Last reviewed: 2026-08-09.

- [ASC MHL documentation](https://ascmhl.readthedocs.io/en/stable/)
- [ASC MHL project](https://ascmitc.github.io/mhl/)
- [OffShoot feature index](https://docs.hedge.video/offshoot/features)

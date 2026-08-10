# Offload Model

The shared vocabulary and the correctness contract for doppelganger's core.
Read this before writing or reviewing anything that copies, hashes, verifies, or
removes files. Code, tests, UI strings, and logs should all use these terms with
these meanings.

---

## Vocabulary

| Term | Meaning |
|------|---------|
| **Source** | The volume or folder footage is read from — typically a mounted camera card. Treated as read-only for the entire lifetime of a transfer. |
| **Destination** | A folder the footage is written to. A transfer has **one or more**; multi-destination is a core feature, not an add-on. |
| **Item** | One file being offloaded, with its relative path preserved from the source root. |
| **Task** | The durable user-facing job. It owns mutable organizational metadata and aggregates one or more immutable attempts. |
| **Attempt** | One execution of copy, resume, retry, standalone verification, cascade, or contact-sheet work. It never overwrites an earlier attempt. |
| **Operator Profile** | A local, non-authenticated identity selected in the app. Attempts and state-changing audit events snapshot its stable ID and display name. |
| **Copy pass** | The write phase — reading items from the source and writing them to each destination. |
| **Verification pass** | The read-back phase — independently hashing what landed at each destination and comparing to the source hash. |
| **Manifest** | The written record of a transfer: every item, its size, its checksum, its destinations, and its per-destination verification result. |
| **Result** | Per item, per destination: `verified`, `transferredPendingVerification`, `failed`, or `skipped`, always with explicit evidence. |

## The contract

The ordering below is not an implementation preference. It is the guarantee the
product exists to provide, and [Principle 3](../../../AGENTS.md#principles) makes
it non-negotiable.

```
1. Enumerate    — walk the source, produce the item list, total the bytes
2. Copy         — write every item to every destination
3. Verify       — re-read each written copy and compare checksums
4. Manifest     — write the record, including any failures
5. Report       — success only if every item verified at every destination
```

Rules that follow from it:

- **A copy is not a verified success.** Only a passed verification is. Progress
  at 100% means the copy pass finished, nothing more. Fast-profile output is
  yellow `Transferred — verification pending`, never green.
- **Verification re-reads from disk.** Comparing an in-memory hash computed
  during the write against itself proves nothing — it would pass even if the
  write never reached the platter. Read the destination file back.
- **A source is never modified.** No deletion, no move, no metadata write, no
  `.DS_Store`. Open read-only and keep it that way.
- **Partial failure is failure.** If one destination of three fails
  verification, the transfer failed. Report exactly which items and which
  destinations, and never collapse that into a single green checkmark.
- **Interruption is a defined outcome.** A yanked card or unmounted destination
  produces a manifest describing what was verified before the interruption. It
  never produces silence, and never produces success.
- **Publishing a file is atomic.** Bytes are written and closed under a hidden,
  transfer-scoped staging name, then exclusively renamed to the final name.
  A crash or failed write never leaves a partial file masquerading as footage.
- **Core evidence is part of success.** If required JSON/Markdown/ASC MHL records
  cannot be written everywhere expected, the transfer is failed even when all
  media bytes verified. No stale `verified` record or partial MHL remains.
  Optional artifacts such as a contact sheet have their own warning state and
  cannot retroactively invalidate verified media.
- **The source plan is stable.** Size and modification metadata are checked
  before a staged file is published, and the complete source is enumerated
  again after copy/verification. A changing source fails the transfer.
- **An empty or zero-byte source is not success.** It is blocked before any
  destination media is touched and recorded as a failed run in the app spool.
- **Each offload owns a new output folder.** Preflight rejects existing output
  roots and overlap with the source. Name collisions never overwrite a file.

## Verification profiles

| Profile | Required reads | Terminal meaning |
|---|---|---|
| **Fast** | Hash the source during copy; validate destination size and metadata only. | Yellow `Transferred — verification pending`; unsafe to eject until a later standalone verification passes. |
| **Standard** | Hash the source during copy and fully re-read every destination uncached. | Green only after all copies match; product default. |
| **Maximum** | Independent source pre-read, copy, then full uncached destination read-back. | Green only after all three phases complete. |

A standalone verification is a new attempt. It may upgrade the task aggregate
from pending to verified, but the earlier Fast attempt remains immutable.

## Checksums

| Algorithm | Role |
|-----------|------|
| **XXH3-64** | Default and fastest supported choice. Not cryptographic; the threat model is accidental corruption rather than a malicious forger. |
| **XXH64BE** | ASC MHL-compatible xxHash64 representation. |
| **MD5** | Compatibility. Required for MHL manifests other tools will read, and for facilities that mandate it. Slower. |

Requirements either way:

- **Stream in bounded chunks.** Media files reach hundreds of gigabytes; never
  read a whole file into memory.
- **Hash the source once**, during the copy pass, and reuse that digest for
  every destination comparison. Re-reading the card per destination is both slow
  and needless wear.
- **Algorithm choice is Settings-only and snapshotted per task.** Running,
  resumed, and retried attempts retain their original algorithm. A manifest
  whose algorithm is unknown is not verifiable later.

## Tasks, attempts, and attribution

- Task organization (Project, Shooting Day, Camera/Card) may change later;
  manifests, attempts, item results, and audit events may not.
- Resume, retry, Verify Again, cascade, and contact-sheet work create linked
  attempts. Nothing edits a failure into success.
- The active Operator Profile is visible before Start. An attempt records the
  profile that initiated it; each state-changing user action records the active
  profile at that moment.
- Profile attribution is declarative local provenance, not authentication. A
  rename or archive never changes the stored display-name snapshot.
- System completion/failure events identify the system as actor and retain the
  initiating Profile for context.

## Manifests

The manifest is the deliverable that outlives the app session. It must record
enough for someone else, with different software, to re-verify the copy:
algorithm, per-item relative path, size, digest, destination, result, and
timestamps.

**MHL** (Media Hash List) is the interchange format professionals already use and
the format to target for compatibility. A richer native format alongside it is
acceptable; replacing MHL with a proprietary-only format is not.

## Failure modes to design for

These are ordinary runtime states, not exceptional ones. Each needs a typed
failure and a defined manifest outcome:

- source unmounted mid-transfer (card pulled)
- destination unmounted mid-transfer (drive unplugged)
- destination full, or fills partway through
- unreadable source file (bad sector, permissions)
- checksum mismatch on read-back
- name collision at a destination
- filesystem case-sensitivity mismatch between source and destination
- filename or path length limits on the destination filesystem
- machine sleeps mid-transfer
- source contents or metadata change during transfer
- empty source or zero-byte source item
- source/destination or two destinations share one physical volume
- required manifest/report/MHL evidence cannot be written
- app exits before a terminal report (recovered from a durable journal)

# Product Vision

## The problem

On a shoot, footage exists in exactly one place — a card in a camera — until
someone copies it off. That copy is the single riskiest operation in the whole
production. A drag-and-drop in Finder gives no proof the bytes arrived intact, no
record of what was transferred, and no protection against the card being wiped on
a copy that silently truncated.

## What doppelganger does

Offload media from camera cards to one or more destinations, **verify** every
copy by checksum, and write a manifest recording exactly what moved and whether
it survived the trip. Nothing reports success until verification passes.

## Who it's for

Camera assistants, DITs, solo shooters, and editors — people standing next to a
card reader who need to know, before they hand the card back, that the footage is
safe. They are usually tired, often in a hurry, and the cost of an unnoticed
failure is unrecoverable.

That audience dictates the design posture:

- **Fast** — the tool is on the critical path of a wrap. Hashing must not double
  the copy time.
- **Loud about failure, quiet about success.** Ambiguity is the enemy. A partial
  verification must be impossible to mistake for a good one.
- **Trustworthy under interruption.** Cards get yanked, drives get unplugged,
  laptops sleep. The tool must be honest about what completed.
- **Review before writing.** Operators see exact output folders, volume
  independence, capacity, empty/zero-byte findings, and blocking issues before
  an offload starts.
- **Readable at task density.** Several simultaneous offloads must remain
  scannable; animation and translucent decoration cannot compete with status.

## Scope

**In scope:** multi-destination copy, streaming checksum verification, transfer
manifests/logs, source and destination selection with persistence across launches,
progress reporting, clear per-file result reporting, resource-aware multi-task
queueing, durable history, interruption recovery, and an optional Project /
Shooting Day context for organizing both new work and historical transfer tasks.
Transfers must remain possible without creating or selecting a Project, and
organizational changes must never rewrite their verification evidence.

**Explicitly deferred:** cloud upload, transcoding, proxy generation, media
playback and review, and any form of card formatting or source deletion. Source
deletion in particular is a feature that must be designed with far more care than
the rest of the app combined — see
[Principle 3](../../../AGENTS.md#principles) — and is not part of the initial
product.

## Prior art

Hedge and Offshoot define the category and the user expectations. Where a
behavior is ambiguous, matching the established convention of those tools is a
reasonable default — particularly around manifest formats (MHL) and the
copy-then-verify ordering that professionals already trust.

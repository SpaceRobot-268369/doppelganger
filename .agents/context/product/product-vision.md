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

The complete 1.0 is a local, professional offload product rather than a narrow
demo. It combines verified multi-destination transfer with pause/resume,
standalone verification, ASC MHL, multi-source queueing, destination and project
libraries, camera-media health checks, optional contact sheets, durable history,
multiple local Operator Profiles, onboarding, Help, and bilingual UI. The stable
commitment list is [`features.md`](features.md).

Projects are optional. Transfers can always live in No Project, and later
organization changes never rewrite verification evidence. Operator Profiles are
also local declarations, not authenticated accounts: the active profile makes
responsibility visible and is snapshotted in task, attempt, and audit history.

**Explicitly outside 1.0:** cloud upload, transcoding, proxy generation, media
playback/review, remote monitoring, remote notifications, NLE export, automation
interfaces, selective copy, path reorganization, and every form of card
formatting or source deletion. See [Principle 3](../../../AGENTS.md#principles).

The project is open source under GPL-3.0-only. There is no trial, commercial
license state, account service, purchase restoration, paid update channel, or
telemetry requirement.

## Prior art

Hedge and Offshoot define the category and the user expectations. Where a
behavior is ambiguous, matching the established convention of those tools is a
reasonable default — particularly around manifest formats (MHL) and the
copy-then-verify ordering that professionals already trust.

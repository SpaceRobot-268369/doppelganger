# Design Language

The product uses Apple's current macOS visual language, including Liquid Glass, to
make a high-stakes utility feel native and calm. Glass is an interaction and
navigation material, not the default background for every piece of data.

## Product concept

![Doppelganger Liquid Glass multi-task concept](assets/doppelganger-liquid-glass-multitask-concept.png)

The concept establishes the overall composition: a compact macOS sidebar,
several simultaneously visible transfer cards, direct source-to-destination
topology, per-destination progress, and expandable operational detail.

It is a direction reference rather than a pixel specification. In particular,
the green checks shown on active connectors in this early concept are
superseded by the status rules below: an active copy or verification is blue or
cyan; green appears only after verification and evidence writing have passed.

## Non-negotiable visual semantics

1. **Source fans out directly.** Every destination has its own line from the
   source. Never draw `source → destination 1 → destination 2` unless a future
   cascading transfer is explicitly modeled as separate transfers. A multi-source
   review may bundle its sources at one junction before the fan-out — that is a
   drawing device to keep the picture readable, never a copy path, and the
   junction states how many independent tasks it stands for.
2. **Green means verified.** Copying is blue, verification is cyan, queued and
   neutral states are gray, Fast-profile `Transferred — verification pending`
   is yellow, warnings are orange, and failed/incomplete states are red.
   Reaching 100% of the copy pass does not earn a checkmark.
3. **Failure keeps its shape.** A failed destination shows its verified
   fraction and error count; it does not jump to 100%. A card with any failure
   cannot use the quiet success treatment.
4. **Evidence affects the verdict.** A transfer whose media copied and verified
   but whose required evidence could not be written is red/failed, with the
   transfer-level issue visible in the card and report.
5. **Source safety is explicit.** Failed/interrupted cards say to keep the
   source. Eject is offered only for the removable source-volume root after a
   verified terminal result. Formatting and source deletion are absent.

## Liquid Glass usage

- Use Liquid Glass for the sidebar selection, filter chips, primary/secondary
  controls, compact icon controls, sheets, and small transient callouts.
- Use quieter opaque or system background surfaces for transfer cards,
  destination rows, manifests, preferences, and failure detail. Dense nested
  glass reduces hierarchy and legibility.
- Settings is a dedicated in-app sidebar tab so configuration stays in the
  main workflow; `⌘,` selects that tab. Keep menus, folder pickers, keyboard
  shortcuts, and accessibility behavior native to macOS.
- Maintain contrast in light/dark appearances and Increased Contrast. Do not
  encode state with color alone; pair it with text and/or a symbol.

## Multi-task dashboard

- Default completed and background tasks to a compact row showing label,
  source, direct destination summary, truthful phase/verdict, and progress.
- Automatically expand the first running task; let the operator expand any
  task without changing its execution state.
- A task owns its own engine and evidence. The queue may run independent
  physical volumes concurrently, but it must not contend on the same source or
  destination volume.
- Reduce decorative animation frequency and honor Reduce Motion. Live motion
  communicates activity, not success.

## Secondary pages

Creating and reviewing work happens on secondary pages inside the app, not in
modal windows. New Offload, New Project, and a project's detail all replace the
current detail area in place.

- A modal is for a short confirmation. Anything the operator reads, compares, or
  edits — a plan under review, a production being set up — is a page.
- Every secondary page opens with the same circular Liquid Glass back control at
  the top left, chevron only, before the page title. `⌘[` also goes back.
- Page transitions are **not** animated. Routing runs inside a transaction with
  animations disabled so the working surface appears immediately.
- A page owns its own footer actions; the primary action is glass-prominent and
  keeps the default keyboard shortcut, and Cancel/back never destroys work
  silently.

## Buttons and controls

- Anything that reads as a control uses Liquid Glass: `.glass` for standard and
  compact icon controls, `.glassProminent` with a tint for the single primary
  action on a surface. Menus that act as controls use the button menu style over
  glass, not the borderless style.
- Plain styling is reserved for surfaces that are **not** controls in their own
  right: selectable cards and list rows, sidebar rows with their own selection
  treatment, filter chips that draw their own glass, and inline field
  affordances such as a search field's clear glyph.
- Compact icon controls carry both a Help string and an accessibility label.
- Do not mix link-styled text actions into a row of glass controls.

## In-page option and filter navigation

- When a page has several peer sub-options or status filters, use the Transfers
  pattern: separate Liquid Glass capsule chips in a row beneath the page title.
  Do not substitute a joined segmented control for this pattern.
- A chip may pair its label with a small semantic-color dot and a live count.
  The selected chip uses the blue-tinted glass treatment; the status dot still
  follows the product's truthful color semantics.
- The entire visible capsule is the hit target. Selection does not change its
  padding or geometry, so the control never shifts away from the pointer.
- Reuse the same shared component, spacing, typography, and count animation on
  Transfers, Manifests, Project history, and future pages with comparable peer
  filters. A simple binary or form choice may still use the native control that
  best matches macOS conventions.

## Project context

- Project is an optional working context. Always provide a clear “No Project”
  or global “All Transfers” route rather than forcing setup before an offload.
- Show the active project near the workflow entry point so the destination of
  newly created tasks is understandable before the user presses Start.
- Selecting a project anywhere a task is created shows what was selected:
  production company, location, shoot dates, transfer and camera counts, and
  last activity. Choosing a context should never be a bare name in a menu.
- History can reveal a Project → Shooting Day → Camera/Card hierarchy, but each
  transfer remains independently identifiable and directly reachable.

## Output layout

Every transfer states where its files land, and the page shows the literal path
in **every** destination before anything is written — each destination receives
its own complete copy, so showing only the first would describe part of the
plan. Paths stop at the folder rather than naming an example file, and a
multi-source plan shows the naming pattern instead of one source's folder name.

- **New folder** (default): a folder named for the transfer is created inside
  each destination. This is the only layout whose output is guaranteed to start
  empty, so an existing folder of that name blocks the transfer.
- **Directly in destination**: files are written into the destination root,
  beside whatever is already there. There is no empty-output guarantee, so
  preflight looks for paths the plan would collide with and blocks on them. The
  engine never overwrites: a collision fails that file, it does not replace it.
- The batch rule that each source needs a unique folder name applies to the
  new-folder layout only; writing directly has no per-task folder to be unique.

The transfer-folder name follows the industry convention **strictly**:
`YYYYMMDD_REEL`, as in `20260810_A001`. It is derived, never typed — there is no
free-form folder field to drift away from the convention, and a naming preset
does not override it. The reel comes from the Shooting Info section, falling
back to the source's own name until one is entered; picking a project camera
fills it with that camera's next reel. The date is the operator's local calendar
date, not GMT. Cascade and retry name their outputs distinctly, because those
must not land in the folder they were derived from.

## Cameras and reel names

- A project owns its cameras. Each camera holds a reel letter, a crew-facing
  name, and optional make/model, managed on the project's Cameras page.
- Tape/reel names follow the industry convention: the camera's letter plus a
  running number — A001, A002 for the A camera, B001 for the B camera. Reel
  letters are unique within a project while the camera is active.
- New Offload offers the selected project's cameras and suggests the next reel
  name from what that camera already offloaded. Both the camera and card labels
  stay editable; the suggestion is never binding.
- Retiring a camera removes it from future selection only. Past transfers keep
  the camera and reel labels they were recorded with.
- Moving a historical task between organizational containers must look like
  metadata organization, never like the underlying verified evidence moved or
  changed.

## Operator identity

- The active local Operator Profile is always visible at the bottom of the
  sidebar as an avatar plus display name. This is provenance, not login state.
- Clicking that identity opens a compact profile switcher; creation, editing,
  avatar choice, import, and archival live in Settings → Profiles.
- New Offload repeats the active profile near the Start action. Task and Attempt
  detail show the initiating avatar/name, and History exposes an audit timeline
  for state-changing actions.
- Imported avatar photos and initials/color avatars share the same circular
  presentation. Archived profiles remain renderable in historical records.

## Drag and drop

- Every source, destination, ASC MHL, and avatar selection surface accepts the
  equivalent Finder drag-and-drop operation.
- A single source fills the draft. Multiple sources open batch review. A
  destination drop adds it to the reviewed plan or Destination Library.
- **A drop transfers exactly what was dropped.** A dropped folder is transferred
  whole. Dropped files are transferred as those files: they are grouped under
  the folder that holds them so output paths stay meaningful, and nothing else
  under that folder joins the plan. The source tile names the files themselves
  rather than collapsing them into a count, and never silently widens a file
  selection back to its folder.
- Every source and destination tile offers Reveal in Finder. For a file
  selection it reveals those files, not the folder around them.
- A drop never starts, queues, ejects, or otherwise performs consequential work.
- Invalid items leave the prior selection intact and explain what is accepted.
- Drop targets must be hit-testable across their whole visible area. An unfilled
  outline or a transparent column is not a drop target where it looks like one.

## New Offload review

The start page is a review checkpoint, not a form that launches blindly. It
must show:

- the output layout, and the exact output path per destination under it;
- transfer/output-folder name when a folder is being created;
- source item count and bytes;
- available capacity with working reserve;
- empty and zero-byte findings;
- source/destination overlap, existing-folder, mount, read-only, and physical
  volume independence checks;
- explicit acknowledgement for same-volume/non-independent copy warnings.

Changing any input invalidates the prior preflight. Start remains disabled
until the displayed plan matches the request exactly.

### Composition

The page asks a small number of things and shows the rest.

- **The plan is drawn as a topology**, not a list of labelled fields: sources in
  a left column, destinations in a right column, and one connector curve per
  source/destination pair — the same fan-out language as a running transfer
  card. Connectors stay neutral until preflight has actually inspected the plan,
  then take the plan's verdict colour (blue ready, orange warning, red blocked).
  With several sources, the hovered source's curves stay solid while the rest
  fade back.
- **Both columns are drop targets with visible affordances.** Each ends in a
  dashed drop well naming what it accepts and offering the equivalent folder
  picker. Targeting tints the column; an invalid drop leaves the plan untouched
  and says what is accepted.
- **Verification, checksum, project, camera, and operator sit directly below the
  graph.** The checksum is chosen per task — Settings holds only the default for
  new tasks, and a task-level choice survives unrelated Settings writes. Project
  is a picker with a first-class "No Project" entry that reveals the selected
  production's details. The camera picker offers that project's cameras. The
  operator picker chooses which profile the task is credited to, defaulting to
  the active one.
- **Shooting Info sits directly under the plan** — shooting day, camera, reel
  name, and the workflow preset. These are catalog labels, but the reel also
  names the transfer folder, so the section belongs with the plan rather than
  behind a disclosure. "Card" is called Reel Name, the term the camera
  department uses.
- **The preflight verdict leads with the decision.** Counts, bytes, exact output
  paths, free space, blocking issues, warnings, notices, and the same-volume
  acknowledgement are always visible. Supporting detail folds into disclosures:
  the scanned source's file tree, media analysis with ASC MHL status, and
  prior-offload history. A disclosure holding anything that needs attention
  carries a marker on its label, so nothing important hides behind a chevron.
- The source tree is rendered from the plan the scan already produced. Browsing
  it reads nothing from disk, and a single directory renders a bounded number of
  entries before summarizing the remainder.

## Accessibility and performance

- Every icon-only control has a concrete accessibility label and Help text.
- Target controls are comfortably clickable; selection must not shift the hit
  area beneath the pointer.
- Text can be selected where an operator may need to report an error or path.
- Progress updates are throttled; the UI never reads free-space metadata or
  hashes files on every render pass.
- Dense task cards remain scannable at the minimum supported window size.

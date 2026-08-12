# Box chip colours — design

**Date:** 2026-08-12
**Status:** Approved (Dan: "auto is fine")

## Goal

Each machine (agent box) gets a distinct tag colour, so the box chip beside
a chat title reads at a glance — eric is always the same colour, everywhere.

## Decision: automatic colour assignment

Dan chose automatic over user-picked. The colour is derived deterministically
from the box's display name — zero setup, no storage, no sync, and the same
name yields the same colour on iOS, Mac, and (portably) Android.

Renaming a box re-rolls its colour. That matches the mental model: the colour
tags the *name*, and renames are rare deliberate acts (Settings → rename,
shipped in #131).

## Colour derivation

- **Hash:** FNV-1a (32-bit) over the display name's UTF-8 bytes. Explicitly
  NOT Swift's `Hashable`/`hashValue`, which is seed-randomised per launch.
- **Palette:** a fixed array of 10 hues that read in both light and dark
  mode: blue, green, orange, purple, teal, pink, indigo, brown, cyan, mint
  (the SwiftUI system colours, which adapt to appearance automatically).
- **Index:** `hash % palette.count`. Collisions between two box names are
  acceptable (10 hues, typical fleets < 15 boxes; colour is an aid, not an
  identifier — the name is still printed in the chip).

## Rendering

`BoxChip` keeps its shape, typography, truncation, and accessibility label.
Only the fill changes, GitHub-label style:

- background: `tint.opacity(0.18)` (was `Color.secondary.opacity(0.15)`)
- text: `tint` (was `.secondary`)

## Placement

All logic lives in `MatronShared/Sources/DesignSystem/BoxChip.swift`:

- `BoxChip.tint(for name: String) -> Color` — public static, so Settings or
  the chooser can reuse it later. Not adopted anywhere else in this pass.
- The FNV-1a hash as a small internal static, unit-testable.

Both chat lists (iOS `ChatListView`, Mac `MacChatListView`) already render
`BoxChip(boxName)` — they pick the colour up for free, no call-site changes.

## Testing

- Unit test pinning fixture names → palette indices (e.g. `"eric"`,
  `"dan-mac"`, `"build-7"`, `""`, an emoji name), so the hash/palette can
  never silently change and re-shuffle everyone's colours.
- Unit test: same name twice → same index (determinism), two differing
  names from the fixtures → observed distinct indices.
- Add a `BoxChipTests` snapshot (light/dark/axxxl via `assertVariants`)
  pinning the coloured rendering — the chip had no visual baseline before.

## Out of scope (YAGNI)

- Manual colour override in Settings (revisit only if auto collisions annoy).
- Colouring the box name anywhere else (Settings device list, New Chat
  chooser, session status sheet).
- Storing colour in the journal / syncing it.

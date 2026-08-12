# Box Chip Colours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each agent box's chip a deterministic colour derived from its display name, identical on every platform and launch.

**Architecture:** All logic lives in the shared `BoxChip` view: a 32-bit FNV-1a hash of the name's UTF-8 bytes indexes a fixed 10-colour palette of SwiftUI system colours. Call sites (iOS + Mac chat lists) are untouched.

**Tech Stack:** SwiftUI, XCTest, swift-snapshot-testing (via the existing `assertVariants` helper).

## Global Constraints

- Hash MUST be FNV-1a 32-bit (offset `2166136261`, prime `16777619`, wrapping multiply) — never Swift `hashValue` (seed-randomised per launch).
- Palette order is frozen: blue, green, orange, purple, teal, pink, indigo, brown, cyan, mint. Reordering re-shuffles every user's colours.
- Chip stays single-line truncating (ChatRowHeightTests fixed-height invariant) — do not touch layout, only fills.
- Snapshot tests skip when `MATRON_SKIP_SNAPSHOT_TESTS=1`; run them locally without that var to record baselines.

---

### Task 1: Deterministic tint derivation

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/BoxChip.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift`

**Interfaces:**
- Produces: `BoxChip.paletteIndex(for name: String) -> Int` (static, internal), `BoxChip.tint(for name: String) -> Color` (static, public), `BoxChip.palette: [Color]` (static, internal, count 10).

- [ ] **Step 1: Write the failing tests**

Append to `BoxChipTests.swift` inside the class:

```swift
    /// Pins name → palette index for fixed fixtures. If this test breaks,
    /// the hash or palette changed and every user's colours re-shuffle —
    /// that must never happen silently.
    func testPaletteIndexIsPinned() {
        XCTAssertEqual(BoxChip.paletteIndex(for: "eric"), 4)
        XCTAssertEqual(BoxChip.paletteIndex(for: "dan-mac"), 4)
        XCTAssertEqual(BoxChip.paletteIndex(for: "build-7"), 9)
        XCTAssertEqual(BoxChip.paletteIndex(for: ""), 1)      // FNV offset basis % 10
        XCTAssertEqual(BoxChip.paletteIndex(for: "🦊 box"), 1) // multi-byte UTF-8
    }

    func testPaletteIndexIsDeterministicAndInRange() {
        for name in ["eric", "dan-mac", "build-7", "", "🦊 box", "a-very-long-box-name-that-will-not-fit"] {
            let first = BoxChip.paletteIndex(for: name)
            XCTAssertEqual(first, BoxChip.paletteIndex(for: name))
            XCTAssertTrue((0..<BoxChip.palette.count).contains(first))
        }
        // Distinct fixtures observed to land on distinct hues.
        XCTAssertNotEqual(BoxChip.paletteIndex(for: "eric"), BoxChip.paletteIndex(for: "build-7"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path MatronShared --filter BoxChipTests 2>&1 | tail -5`
Expected: compile FAILURE — `type 'BoxChip' has no member 'paletteIndex'`.

- [ ] **Step 3: Implement derivation**

In `BoxChip.swift`, add inside `struct BoxChip` (below the initializer):

```swift
    /// Fixed hue palette. Order is frozen — reordering or inserting entries
    /// re-rolls every user's box colours (testPaletteIndexIsPinned pins it).
    /// System colours, so light/dark adaptation comes for free.
    static let palette: [Color] = [
        .blue, .green, .orange, .purple, .teal,
        .pink, .indigo, .brown, .cyan, .mint,
    ]

    /// Deterministic colour for a box name: same name → same colour on
    /// every platform, every launch (and portably on Android). Collisions
    /// between names are fine — the colour is an aid, the name is printed.
    public static func tint(for name: String) -> Color {
        palette[paletteIndex(for: name)]
    }

    /// FNV-1a (32-bit) over UTF-8, mod palette size. Explicitly not
    /// `Hashable` — Swift's hash seed changes per launch.
    static func paletteIndex(for name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(palette.count))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter BoxChipTests 2>&1 | tail -5`
Expected: PASS (3 tests: the pre-existing single-line test + the 2 new ones). Assert the "Executed N tests" line shows 3, per repo rule.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/BoxChip.swift MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift
git commit -m "feat(design): deterministic per-box tint for BoxChip

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Coloured chip rendering + snapshots

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/BoxChip.swift:18-28` (the `body`)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift`

**Interfaces:**
- Consumes: `BoxChip.tint(for:)` from Task 1.
- Produces: no new API — visual change only.

- [ ] **Step 1: Add the snapshot test**

Append to `BoxChipTests.swift` (add `import SwiftUI` at the top if not present):

```swift
    /// Visual baseline: two chips whose fixture names land on different
    /// palette hues, side by side, light/dark/axxxl.
    func testChipColorSnapshots() {
        let row = HStack(spacing: 6) {
            BoxChip("eric")     // palette index 4
            BoxChip("build-7")  // palette index 9
        }
        .padding(8)
        assertVariants(of: row, named: "BoxChip_colors")
    }
```

- [ ] **Step 2: Update the chip body**

In `BoxChip.swift`, replace the two fill lines of `body`:

```swift
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
```

with:

```swift
            .background(Self.tint(for: displayName).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.tint(for: displayName))
```

- [ ] **Step 3: Record baselines and verify**

Run: `swift test --package-path MatronShared --filter BoxChipTests 2>&1 | tail -5`
Expected: FIRST run FAILS with "No reference was found on disk. Automatically recorded snapshot" (3 new `mac-BoxChip_colors-*` files under `__Snapshots__/BoxChipTests/`). SECOND run of the same command PASSES with "Executed 4 tests".

- [ ] **Step 4: Eyeball the recorded baselines**

Run: `open MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/BoxChipTests/`
Expected: chips read as tinted capsules (teal-ish and mint-ish), legible text in both light and dark variants.

- [ ] **Step 5: Full shared-package test sweep**

Run: `swift test --package-path MatronShared 2>&1 | tail -3`
Expected: all tests pass; "Executed N tests" present with 0 failures (other snapshot suites re-render locally — any unrelated failure here is pre-existing drift, stop and report rather than re-recording others).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/BoxChip.swift MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/BoxChipTests/
git commit -m "feat(design): colour the box chip per machine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

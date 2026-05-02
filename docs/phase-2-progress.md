# Phase 2 — Chat Experience: Progress

This file tracks Phase 2 implementation progress. Updated as each task ships.

**Plan:** `docs/superpowers/plans/2026-05-02-matron-ios-phase-2-chat-experience.md`

**Branch:** `phase-2-chat-experience`

## Status

Started 2026-05-02. Phase 1 shipped; this branch builds on top.

## Tasks (will be checked off as completed)

See the plan for the canonical task list. Progress updates land here per push so a PR reviewer can scan a single file for context.

- [x] **Task 1** — MarkdownUI + swift-snapshot-testing wired into `MatronShared/Package.swift`; added `DesignSystemSnapshotTests` test target. `MatronDesignSystem` was already declared in `project.yml` from Phase 1, so no project-yml churn.
- [x] **Task 2** — `MarkdownText` primitive shipped with `Theme.matron` (system font, monospaced inline code, copy-button code blocks, accent-coloured underlined links). 4 snapshot tests × 3 macOS variants = 12 baselines recorded. Plan deviation: `swift-snapshot-testing` only ships a SwiftUI-aware `.image` strategy on iOS/tvOS, so on macOS the `assertVariants` helper hosts the SwiftUI view in `NSHostingView` and snapshots that. iOS variants will be wired up when this suite gets a host xcodebuild scheme.

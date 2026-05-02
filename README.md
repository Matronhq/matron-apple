# Matron

Native Matrix client for iOS and macOS, bot-first, App Store distributable on both platforms. Built on [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

Part of the [Matron](https://github.com/matronhq) ecosystem.

## Status

Pre-alpha. Phase 1 (foundation) in progress — see `docs/superpowers/plans/`.

## Requirements

- macOS 14+
- Xcode 16+
- A Matrix homeserver — recommend [matron-server](https://github.com/matronhq/matron-server) provisioned via [dev-boxer](https://github.com/matronhq/dev-boxer).

## Building

```bash
xcodegen generate
open Matron.xcodeproj
```

- For iPhone/iPad: select the `Matron` scheme, choose an iOS 17+ simulator or device, build & run.
- For macOS: select the `MatronMac` scheme, build & run on the host (macOS 14+).

## Tests

```bash
# iOS
xcodebuild test -workspace Matron.xcworkspace -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 15'

# macOS
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac -destination 'platform=macOS'
```

## License

AGPL-3.0 with commercial licensing available by arrangement. See `LICENSE`, `NOTICE`, and `CONTRIBUTING.md`.

## Contributing

External contributions require a signed CLA — see `CONTRIBUTING.md` and `.cla.md`. The `cla-assistant` GitHub bot prompts for signature on first PR.

## Documentation

- Design spec: `docs/superpowers/specs/2026-05-02-matron-ios-design.md`
- Implementation plans: `docs/superpowers/plans/`

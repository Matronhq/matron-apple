# Matron iOS

Native iOS Matrix client, bot-first, App Store distributable. Built on [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

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

Select the `Matron` scheme, choose an iOS 17+ simulator or device, build & run.

## Tests

```bash
xcodebuild test -workspace Matron.xcworkspace -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 15'
```

## License

Apache 2.0. See `LICENSE`.

## Documentation

- Design spec: `docs/superpowers/specs/2026-05-02-matron-ios-design.md`
- Implementation plans: `docs/superpowers/plans/`

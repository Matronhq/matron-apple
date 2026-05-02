# Contributing to Matron

Thanks for your interest. This document explains the project's licence model and how to contribute.

## Project licence

Matron is dual-licensed:

- **AGPL-3.0** for open source use. Source redistribution and modified-version network deployments must comply.
- **Commercial licensing** is available by arrangement for redistributors who cannot comply with AGPL-3.0. Contact `licensing@matron.chat`.

Matron HQ retains copyright on all first-party code.

## Why we have a CLA

Dual-licensing requires that the copyright holder retain the right to relicense contributions under both AGPL-3.0 and commercial terms. We use a Contributor Licence Agreement (CLA) to make this explicit.

The CLA grants Matron HQ a perpetual, irrevocable, worldwide licence to use, modify, sublicense, and relicense your contribution under any terms — including the commercial licence offered alongside AGPL-3.0. You retain copyright on what you contribute; you simply grant Matron HQ broad rights to use it.

The full CLA text is in [`.cla.md`](.cla.md).

## How to contribute

1. **Fork** the repo on GitHub.
2. **Branch** from `main`, push your changes, **open a pull request** against `matronhq/matron-ios-app:main`.
3. The **`cla-assistant` bot** will comment on your first PR asking you to sign the CLA. Reply with the exact phrase the bot requests; this records your signature in the `signatures/v1/cla.json` file on a CLA branch.
4. A maintainer will review. We aim for first-pass review within a week.

## Scope

- **Bug fixes and small features:** PRs welcome directly.
- **Larger features:** please open an issue first to discuss design before sinking time into a PR — see the design spec at `docs/superpowers/specs/`.
- **Breaking changes to public protocols** (`AuthService`, `ChatService`, etc.): coordinate via issue.

## Commit style

- One logical change per commit.
- Commit messages: short imperative subject (`feat: …`, `fix: …`, `chore: …`, `docs: …`), wrap body at 72 columns if you include one.

## Tests

Every new code path lands with a test. The plan documents in `docs/superpowers/plans/` show the TDD shape we follow (failing test → implementation → verify).

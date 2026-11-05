# Changelog

The current version is `metadata.version` in `sparring/SKILL.md`. Every version is tagged `vX.Y.Z`
in git and published as a GitHub release with its own `.skill` archive. Versions are numbered
MAJOR.MINOR.PATCH.

- **PATCH** (1.0.1) is a fix or clearer wording. The skill behaves the same.
- **MINOR** (1.1.0) is a new or changed rule, or a new harness feature.
- **MAJOR** (2.0.0) changes the `sparctl` commands or how the skill works with the user.

## [1.0.0] - 2026-11-06

The first numbered version. The skill itself is unchanged since `193077f`.

### Added

- The version number in `SKILL.md`.
- The MIT `LICENSE` file. The README already named MIT, but the file was missing.

## Before 1.0.0

- **2026-10-24.** The skill installs as a Claude Code plugin from the
  [nyxandro/skills](https://github.com/nyxandro/skills) catalog (`193077f`).
- **2026-05-31.** Simpler native sessions (`8b02bf0`).
- **2026-05-30.** The `sparctl` harness lives inside the skill, so the archive works without a
  checkout. A sturdier session workflow, a refined prompt protocol and loop rules, a longer
  provider timeout (`951936a` to `e31912f`).
- **2026-05-29.** First release. Native session resume for Claude and Codex, diagnostics and a
  downloadable archive (`673a44d` to `6499e9e`).

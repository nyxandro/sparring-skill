#!/usr/bin/env bash
# skill-layout.sh — regression test for the distributable skill folder.
#
# The skill itself must be self-contained: installing the `sparring/` folder should provide
# both instructions and the runtime harness, without relying on this repository's top-level
# `bin/` or `lib/` directories.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SKILL_DIR="$ROOT/sparring"

fail() { echo "SKILL_LAYOUT_FAIL: $1" >&2; exit 1; }

# Runtime files are part of the skill contract, not developer-only repository helpers.
for path in \
  "$SKILL_DIR/SKILL.md" \
  "$SKILL_DIR/bin/sparctl" \
  "$SKILL_DIR/lib/print-agent.sh" \
  "$SKILL_DIR/lib/tmux-agent.sh"; do
  [ -f "$path" ] || fail "missing bundled skill file: ${path#$ROOT/}"
done

# Entrypoint scripts must stay executable after checkout or manual folder install.
[ -x "$SKILL_DIR/bin/sparctl" ] || fail "bundled sparctl is not executable"

# Test/demo agents must not be shipped inside the installed skill runtime.
[ ! -e "$SKILL_DIR/bin/mock-agent.sh" ] || fail "test mock-agent leaked into the skill"
[ ! -e "$SKILL_DIR/bin/spar" ] || fail "demo dispatcher leaked into the skill"

# The instructions must not require the author's local checkout paths to run.
if grep -R -q '/home/[^`[:space:]]*/projects/' "$SKILL_DIR/SKILL.md" "$ROOT/README.md"; then
  fail "documentation still points at an author's local checkout"
fi

# Fresh sparring must not default to provider-native resume because stale state can leak context.
if grep -q 'Use `ask-resume` by default' "$SKILL_DIR/SKILL.md"; then
  fail "SKILL.md still makes ask-resume the default for fresh sparring"
fi
grep -q 'Use `ask-session` by default for a fresh sparring request' "$SKILL_DIR/SKILL.md" \
  || fail "SKILL.md does not define ask-session as the fresh multi-turn default"
grep -q 'Do not use `ask-resume` for a new sparring request or first turn' "$SKILL_DIR/SKILL.md" \
  || fail "SKILL.md does not warn against ask-resume on a first turn"
if grep -q '`ask-print`' "$SKILL_DIR/SKILL.md"; then
  fail "SKILL.md still recommends ask-print in the user-facing workflow"
fi
# The downloadable archive is the release artifact, so it must match the source skill folder.
ARCHIVE="$ROOT/dist/sparring.skill"
EXTRACTED_DIR="${TMPDIR:-/tmp}/sparring-skill-layout-$$"
cleanup() { rm -rf "$EXTRACTED_DIR"; }
trap cleanup EXIT

[ -f "$ARCHIVE" ] || fail "missing distributable archive: dist/sparring.skill"
mkdir -p "$EXTRACTED_DIR"
unzip -q "$ARCHIVE" -d "$EXTRACTED_DIR" || fail "dist/sparring.skill could not be unpacked"
diff -qr "$SKILL_DIR" "$EXTRACTED_DIR/sparring" >/dev/null \
  || fail "dist/sparring.skill is out of sync with sparring/"
[ -x "$EXTRACTED_DIR/sparring/bin/sparctl" ] \
  || fail "dist/sparring.skill did not preserve sparctl executable bit"

echo "SKILL_LAYOUT_OK: sparring skill folder is self-contained"

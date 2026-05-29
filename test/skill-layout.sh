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
  "$SKILL_DIR/bin/spar" \
  "$SKILL_DIR/bin/sparctl" \
  "$SKILL_DIR/bin/mock-agent.sh" \
  "$SKILL_DIR/lib/print-agent.sh" \
  "$SKILL_DIR/lib/tmux-agent.sh"; do
  [ -f "$path" ] || fail "missing bundled skill file: ${path#$ROOT/}"
done

# Entrypoint scripts must stay executable after checkout or manual folder install.
[ -x "$SKILL_DIR/bin/sparctl" ] || fail "bundled sparctl is not executable"
[ -x "$SKILL_DIR/bin/spar" ] || fail "bundled spar is not executable"
[ -x "$SKILL_DIR/bin/mock-agent.sh" ] || fail "bundled mock-agent.sh is not executable"

# The instructions must not require the author's local checkout path to run.
if grep -q '/home/nyx/projects/sparring' "$SKILL_DIR/SKILL.md"; then
  fail "SKILL.md still points at the author's local checkout"
fi

echo "SKILL_LAYOUT_OK: sparring skill folder is self-contained"

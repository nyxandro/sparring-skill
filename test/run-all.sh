#!/usr/bin/env bash
# run-all.sh — single entrypoint for the Sparring smoke/regression suite.
#
# It keeps CI/manual verification simple: print-first providers, tmux core and sparctl lifecycle
# must all pass before a release artifact is considered healthy.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run the stable print-first path before tmux-specific fallbacks.
bash "$HERE/print.sh"
bash "$HERE/smoke.sh"
bash "$HERE/sparctl.sh"

echo "SPARRING_TESTS_OK: print -> smoke -> sparctl all verified"

#!/usr/bin/env bash
# run-all.sh — single entrypoint for the Sparring smoke/regression suite.
#
# It keeps CI/manual verification simple: native-session providers, tmux core and sparctl lifecycle
# must all pass before a release artifact is considered healthy.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run the stable native-session path before tmux-specific checks.
bash "$HERE/skill-layout.sh"
bash "$HERE/print.sh"
bash "$HERE/smoke.sh"
bash "$HERE/sparctl.sh"

echo "SPARRING_TESTS_OK: skill layout -> print -> smoke -> sparctl all verified"

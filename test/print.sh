#!/usr/bin/env bash
# print.sh - smoke tests for the primary non-interactive sparring backend.
#
# It verifies the production path that should be preferred over TUI scraping: one ask-session
# command creates provider-native state on the first turn, resumes it later, records a local
# audit trail, and fails loudly on empty/provider-broken answers.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SKILL_DIR="$ROOT/sparring"
SPARCTL="$SKILL_DIR/bin/sparctl"
# shellcheck source=../sparring/lib/tmux-agent.sh
source "$SKILL_DIR/lib/tmux-agent.sh"
# shellcheck source=../sparring/lib/print-agent.sh
source "$SKILL_DIR/lib/print-agent.sh"

AGENT="native-session-smoke"
WORK_DIR="${TMPDIR:-/tmp}/sparctl-print-${AGENT}"
SHIM_DIR="$WORK_DIR/bin"
CLAUDE_OUT="$WORK_DIR/claude.txt"
CLAUDE_STATE="$WORK_DIR/claude.log"
CODEX_OUT="$WORK_DIR/codex.txt"
CODEX_STATE="$WORK_DIR/codex.log"
EMPTY_OUT="$WORK_DIR/empty.txt"
EMPTY_STATE="$WORK_DIR/empty.log"
PROVIDER_FAIL_OUT="$WORK_DIR/provider-fail.txt"
PROVIDER_FAIL_STATE="$WORK_DIR/provider-fail.log"
PROVIDER_FAIL_ERR="$WORK_DIR/provider-fail.err"
MISMATCH_STATE="$WORK_DIR/mismatch.log"
MISMATCH_OUT="$WORK_DIR/mismatch.txt"
MISMATCH_ERR="$WORK_DIR/mismatch.err"
ORIGINAL_PATH="$PATH"

# Keep temp files and tmux sessions isolated even when an assertion fails.
cleanup() {
  agent_kill "$AGENT"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { echo "PRINT_SMOKE_FAIL: $1" >&2; exit 1; }

# Sparring answers are often long critical reviews, so the default cap should not kill a
# healthy provider before it can finish. Fast answers still return immediately before the cap.
[ "$SPAR_PRINT_TIMEOUT" = 500 ] || fail "default SPAR_PRINT_TIMEOUT should be 500 seconds"

# Build deterministic provider shims so tests never spend API tokens or depend on network access.
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
has_print=0
has_plan=0
has_text=0
has_session_id=0
has_resume=0
for arg in "$@"; do
  [ "$arg" = "--disallowedTools" ] && { echo "claude shim rejects unsupported disallowedTools form" >&2; exit 1; }
  [ "$arg" = "-p" ] && has_print=1
  [ "$arg" = "--permission-mode" ] && has_plan=1
  [ "$arg" = "--output-format" ] && has_text=1
  [ "$arg" = "--session-id" ] && has_session_id=1
  [ "$arg" = "--resume" ] && has_resume=1
done
[ "$has_print" = 1 ] || { echo "claude shim expected -p" >&2; exit 1; }
[ "$has_plan" = 1 ] || { echo "claude shim expected --permission-mode" >&2; exit 1; }
[ "$has_text" = 1 ] || { echo "claude shim expected --output-format" >&2; exit 1; }
prompt="$(cat)"
[ -n "$prompt" ] || { echo "claude shim expected prompt on stdin" >&2; exit 1; }
if [ "$prompt" = "empty smoke" ]; then
  exit 0
fi
if [ "$prompt" = "provider fail smoke" ]; then
  echo "claude shim simulated provider failure" >&2
  exit 42
fi
if [ "$prompt" = "native claude first" ]; then
  [ "$has_session_id" = 1 ] || { echo "claude shim expected --session-id for first native turn" >&2; exit 1; }
  printf '[claude-native-first] %s\n' "$prompt"
  exit 0
fi
if [ "$prompt" = "native claude second" ]; then
  [ "$has_resume" = 1 ] || { echo "claude shim expected --resume for continued native turn" >&2; exit 1; }
  printf '[claude-native-second] %s\n' "$prompt"
  exit 0
fi
printf '[claude-native] %s\n' "$prompt"
EOF
cat > "$SHIM_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
original_args="$*"
printf '%s\n' "$original_args" | grep -q -- "exec" || { echo "codex shim expected exec" >&2; exit 1; }
out=""
is_resume=0
has_json=0
has_sandbox=0
has_skip_git=0
has_color=0
for arg in "$@"; do
  [ "$arg" = "--ask-for-approval" ] && { echo "codex shim rejects global approval flag in exec" >&2; exit 1; }
  [ "$arg" = "resume" ] && is_resume=1
  [ "$arg" = "--json" ] && has_json=1
  [ "$arg" = "--sandbox" ] && has_sandbox=1
  [ "$arg" = "--skip-git-repo-check" ] && has_skip_git=1
  [ "$arg" = "--color" ] && has_color=1
done
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    out="${2:-}"
    shift 2
    continue
  fi
  shift
done
[ "$has_skip_git" = 1 ] || { echo "codex shim expected --skip-git-repo-check" >&2; exit 1; }
[ -n "$out" ] || { echo "codex shim expected --output-last-message" >&2; exit 1; }
prompt="$(cat)"
[ -n "$prompt" ] || { echo "codex shim expected prompt on stdin" >&2; exit 1; }
if [ "$prompt" = "native codex first" ]; then
  [ "$has_json" = 1 ] || { echo "codex shim expected --json for first native turn" >&2; exit 1; }
  [ "$has_sandbox" = 1 ] || { echo "codex shim expected --sandbox for first exec" >&2; exit 1; }
  [ "$has_color" = 1 ] || { echo "codex shim expected --color for first exec" >&2; exit 1; }
  printf '{"type":"thread.started","thread_id":"codex-native-thread"}\n'
  printf '[codex-native-first] %s\n' "$prompt" > "$out"
  exit 0
fi
if [ "$prompt" = "native codex second" ]; then
  [ "$is_resume" = 1 ] || { echo "codex shim expected exec resume for continued native turn" >&2; exit 1; }
  printf '%s\n' "$original_args" | grep -q -- "codex-native-thread" || { echo "codex shim expected stored thread id" >&2; exit 1; }
  printf '%s\n' "$original_args" | grep -q -- "--sandbox read-only" || { echo "codex shim expected root read-only sandbox on resume" >&2; exit 1; }
  printf '%s\n' "$original_args" | grep -q -- "-C " || { echo "codex shim expected cwd on resume" >&2; exit 1; }
  printf '[codex-native-second] %s\n' "$prompt" > "$out"
  exit 0
fi
printf '[codex-native] %s\n' "$prompt" > "$out"
EOF
chmod +x "$SHIM_DIR/claude" "$SHIM_DIR/codex"
export PATH="$SHIM_DIR:$ORIGINAL_PATH"

# Claude ask-session should create native state on first use, then resume that exact session.
$SPARCTL ask-session claude "$CLAUDE_STATE" "native claude first" "$CLAUDE_OUT" >/dev/null
grep -q "session_id=" "$CLAUDE_STATE" \
  || fail "claude ask-session state did not store a session id"
grep -q "\[claude-native-first\] native claude first" "$CLAUDE_OUT" \
  || fail "claude first native answer was not captured"
grep -q "USER: native claude first" "$CLAUDE_STATE" \
  || fail "claude state did not record the first user turn"
$SPARCTL ask-session claude "$CLAUDE_STATE" "native claude second" "$CLAUDE_OUT" >/dev/null
grep -q "\[claude-native-second\] native claude second" "$CLAUDE_OUT" \
  || fail "claude ask-session did not continue through --resume"
grep -q "USER: native claude second" "$CLAUDE_STATE" \
  || fail "claude state did not record the second user turn"

# Codex ask-session should extract the provider id from JSON events and resume by that id.
$SPARCTL ask-session codex "$CODEX_STATE" "native codex first" "$CODEX_OUT" >/dev/null
grep -q "session_id=codex-native-thread" "$CODEX_STATE" \
  || fail "codex ask-session state did not store the JSON thread id"
grep -q "\[codex-native-first\] native codex first" "$CODEX_OUT" \
  || fail "codex first native answer was not captured"
$SPARCTL ask-session codex "$CODEX_STATE" "native codex second" "$CODEX_OUT" >/dev/null
grep -q "\[codex-native-second\] native codex second" "$CODEX_OUT" \
  || fail "codex ask-session did not continue through exec resume"

# Providers that exit successfully with an empty answer should fail fast, not create a blank result.
if $SPARCTL ask-session claude "$EMPTY_STATE" "empty smoke" "$EMPTY_OUT" >/dev/null 2>&1; then
  fail "empty provider answer was accepted as a successful response"
fi
[ ! -e "$EMPTY_OUT" ] || fail "empty provider answer left an output file behind"

# Provider failures should preserve enough stderr context to diagnose real CLI breakage.
if $SPARCTL ask-session claude "$PROVIDER_FAIL_STATE" "provider fail smoke" "$PROVIDER_FAIL_OUT" > /dev/null 2> "$PROVIDER_FAIL_ERR"; then
  fail "provider failure was accepted as a successful response"
fi
grep -q "exit status 42" "$PROVIDER_FAIL_ERR" \
  || fail "provider failure did not report the provider exit status"
grep -q "claude shim simulated provider failure" "$PROVIDER_FAIL_ERR" \
  || fail "provider failure did not include provider stderr"
[ ! -e "$PROVIDER_FAIL_OUT" ] || fail "provider failure left an output file behind"

# A state file belongs to one backend; silently reusing it with another CLI would mix contexts.
printf 'provider=codex\nsession_id=codex-native-thread\n' > "$MISMATCH_STATE"
if $SPARCTL ask-session claude "$MISMATCH_STATE" "native claude first" "$MISMATCH_OUT" > /dev/null 2> "$MISMATCH_ERR"; then
  fail "provider-mismatched state file was accepted"
fi
grep -q "SPAR_PRINT_SESSION_PROVIDER_MISMATCH" "$MISMATCH_ERR" \
  || fail "provider mismatch did not report a stable error code"

echo "PRINT_SMOKE_OK: ask-session native providers and failure paths verified"

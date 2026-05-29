#!/usr/bin/env bash
# print.sh — smoke tests for the primary non-interactive sparring backend.
#
# It verifies the production path that should be preferred over TUI scraping: Claude print mode,
# Codex exec mode, native provider resume, file-backed dialogue history, and an explicit tmux
# fallback when print is absent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/tmux-agent.sh
source "$ROOT/lib/tmux-agent.sh"

AGENT="auto-print-smoke"
WORK_DIR="${TMPDIR:-/tmp}/sparctl-print-${AGENT}"
SHIM_DIR="$WORK_DIR/bin"
CLAUDE_OUT="$WORK_DIR/claude.txt"
CODEX_OUT="$WORK_DIR/codex.txt"
SESSION_OUT="$WORK_DIR/session.txt"
SESSION_FILE="$WORK_DIR/session.log"
CLAUDE_RESUME_OUT="$WORK_DIR/claude-resume.txt"
CLAUDE_RESUME_STATE="$WORK_DIR/claude-resume.log"
CODEX_RESUME_OUT="$WORK_DIR/codex-resume.txt"
CODEX_RESUME_STATE="$WORK_DIR/codex-resume.log"
AUTO_OUT="$WORK_DIR/auto.txt"
EMPTY_OUT="$WORK_DIR/empty.txt"
PROVIDER_FAIL_OUT="$WORK_DIR/provider-fail.txt"
PROVIDER_FAIL_ERR="$WORK_DIR/provider-fail.err"
ORIGINAL_PATH="$PATH"

# Keep temp files and tmux sessions isolated even when an assertion fails.
cleanup() {
  agent_kill "$AGENT"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { echo "PRINT_SMOKE_FAIL: $1" >&2; exit 1; }

# Build deterministic provider shims so tests never spend API tokens or depend on network access.
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
has_print=0
has_plan=0
has_text=0
for arg in "$@"; do
  [ "$arg" = "--disallowedTools" ] && { echo "claude shim rejects unsupported disallowedTools form" >&2; exit 1; }
  [ "$arg" = "-p" ] && has_print=1
  [ "$arg" = "--permission-mode" ] && has_plan=1
  [ "$arg" = "--output-format" ] && has_text=1
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
if printf '%s' "$prompt" | grep -q "native claude first"; then
  printf '%s\n' "$*" | grep -q -- "--session-id" || { echo "claude shim expected --session-id for first native resume turn" >&2; exit 1; }
  printf '[claude-native-first] %s\n' "$prompt"
  exit 0
fi
if printf '%s' "$prompt" | grep -q "native claude second"; then
  printf '%s\n' "$*" | grep -q -- "--resume" || { echo "claude shim expected --resume for continued native turn" >&2; exit 1; }
  printf '[claude-native-second] %s\n' "$prompt"
  exit 0
fi
printf '[claude-print] %s\n' "$prompt"
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
  [ "$has_json" = 1 ] || { echo "codex shim expected --json for first native resume turn" >&2; exit 1; }
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
[ "$has_sandbox" = 1 ] || { echo "codex shim expected --sandbox" >&2; exit 1; }
[ "$has_color" = 1 ] || { echo "codex shim expected --color" >&2; exit 1; }
printf '[codex-exec] %s\n' "$prompt" > "$out"
EOF
chmod +x "$SHIM_DIR/claude" "$SHIM_DIR/codex"
export PATH="$SHIM_DIR:$ORIGINAL_PATH"

# Claude print mode should run without tmux and write only the model answer to the output file.
$ROOT/bin/sparctl ask-print claude "print smoke" "$CLAUDE_OUT" >/dev/null
grep -q "\[claude-print\] print smoke" "$CLAUDE_OUT" \
  || fail "claude print output was not captured"

# Codex exec mode should use the non-interactive subcommand rather than a TUI session.
$ROOT/bin/sparctl ask-print codex "exec smoke" "$CODEX_OUT" >/dev/null
grep -q "\[codex-exec\] exec smoke" "$CODEX_OUT" \
  || fail "codex exec output was not captured"

# Providers that exit successfully with an empty answer should fail fast, not create a blank result.
if $ROOT/bin/sparctl ask-print claude "empty smoke" "$EMPTY_OUT" >/dev/null 2>&1; then
  fail "empty provider answer was accepted as a successful response"
fi
[ ! -e "$EMPTY_OUT" ] || fail "empty provider answer left an output file behind"

# Provider failures should preserve enough stderr context to diagnose real CLI breakage.
if $ROOT/bin/sparctl ask-print claude "provider fail smoke" "$PROVIDER_FAIL_OUT" > /dev/null 2> "$PROVIDER_FAIL_ERR"; then
  fail "provider failure was accepted as a successful response"
fi
grep -q "exit status 42" "$PROVIDER_FAIL_ERR" \
  || fail "provider failure did not report the provider exit status"
grep -q "claude shim simulated provider failure" "$PROVIDER_FAIL_ERR" \
  || fail "provider failure did not include provider stderr"
[ ! -e "$PROVIDER_FAIL_OUT" ] || fail "provider failure left an output file behind"

# Session mode should carry previous turns forward by constructing a consolidated prompt.
$ROOT/bin/sparctl ask-session claude "$SESSION_FILE" "first turn" "$SESSION_OUT" >/dev/null
grep -q "USER: first turn" "$SESSION_FILE" \
  || fail "session file did not record the first user turn"
$ROOT/bin/sparctl ask-session claude "$SESSION_FILE" "second turn" "$SESSION_OUT" >/dev/null
grep -q "first turn" "$SESSION_OUT" \
  || fail "second session prompt did not include previous context"
grep -q "USER: second turn" "$SESSION_FILE" \
  || fail "session file did not record the second user turn"

# Native resume mode should continue through provider-owned sessions rather than prompt replay.
$ROOT/bin/sparctl ask-resume claude "$CLAUDE_RESUME_STATE" "native claude first" "$CLAUDE_RESUME_OUT" >/dev/null
grep -q "session_id=" "$CLAUDE_RESUME_STATE" \
  || fail "claude native resume state did not store a session id"
$ROOT/bin/sparctl ask-resume claude "$CLAUDE_RESUME_STATE" "native claude second" "$CLAUDE_RESUME_OUT" >/dev/null
grep -q "\[claude-native-second\] native claude second" "$CLAUDE_RESUME_OUT" \
  || fail "claude native resume did not continue through --resume"

$ROOT/bin/sparctl ask-resume codex "$CODEX_RESUME_STATE" "native codex first" "$CODEX_RESUME_OUT" >/dev/null
grep -q "session_id=codex-native-thread" "$CODEX_RESUME_STATE" \
  || fail "codex native resume state did not store the JSON thread id"
$ROOT/bin/sparctl ask-resume codex "$CODEX_RESUME_STATE" "native codex second" "$CODEX_RESUME_OUT" >/dev/null
grep -q "\[codex-native-second\] native codex second" "$CODEX_RESUME_OUT" \
  || fail "codex native resume did not continue through exec resume"

# Auto mode should prefer print, but fall back to tmux when no print provider exists for the name.
SPAR_AGENT_CMD="$ROOT/bin/mock-agent.sh $AGENT" $ROOT/bin/sparctl ask-auto "$AGENT" "fallback smoke" "$AUTO_OUT" >/dev/null
grep -q "\[$AGENT\] on: fallback smoke" "$AUTO_OUT" \
  || fail "ask-auto did not fall back to the tmux backend"
$ROOT/bin/sparctl stop "$AGENT"

echo "PRINT_SMOKE_OK: print providers -> session history -> tmux fallback verified"

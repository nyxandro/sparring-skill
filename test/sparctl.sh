#!/usr/bin/env bash
# sparctl.sh — smoke test for the persistent control CLI.
#
# It verifies the workflow needed for long-running interactive work: keep an agent session
# alive across commands, send a prompt, read the reply, export the full transcript, list the
# tmux session and stop it explicitly.

set -euo pipefail

# Run this test suite against an isolated tmux server, never the user's default server.
export TMUX=""
export TMUX_TMPDIR="${TMPDIR:-/tmp}"
TMUX_SOCKET="sparctl-test-$$"
TMUX_BIN="$(command -v tmux)"
tmux() { "$TMUX_BIN" -L "$TMUX_SOCKET" "$@"; }
export -f tmux
export TMUX_BIN TMUX_SOCKET

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/tmux-agent.sh
source "$ROOT/lib/tmux-agent.sh"

# Use a deterministic mock so this test never spends API tokens or depends on network access.
export MOCK_THINK_SECONDS=1

AGENT="ctl-smoke"
TASK="persistent session smoke"
OUT_FILE="${TMPDIR:-/tmp}/sparctl-${AGENT}.txt"
DELTA_FILE="${TMPDIR:-/tmp}/sparctl-${AGENT}-delta.txt"
WATCH_FILE="${TMPDIR:-/tmp}/sparctl-${AGENT}-watch.txt"
ONCE_FILE="${TMPDIR:-/tmp}/sparctl-${AGENT}-once.txt"
PATH_SHIM_DIR="${TMPDIR:-/tmp}/sparctl-path-${AGENT}"
STALE_PATH_SHIM_DIR="${TMPDIR:-/tmp}/sparctl-stale-path-${AGENT}"
CWD_PROBE_DIR="${TMPDIR:-/tmp}/sparctl-cwd-${AGENT}"
ONCE_CLI="${TMPDIR:-/tmp}/sparctl-once-cli-${AGENT}.sh"
ORIGINAL_PATH="$PATH"
ORIGINAL_TMUX_PATH_WAS_SET=0
ORIGINAL_TMUX_PATH=""

# Preserve the user's tmux server environment exactly; tests may mutate it deliberately.
remember_tmux_path() {
  local path_line
  if path_line="$(tmux show-environment -g PATH 2>/dev/null)"; then
    ORIGINAL_TMUX_PATH_WAS_SET=1
    ORIGINAL_TMUX_PATH="${path_line#PATH=}"
  else
    ORIGINAL_TMUX_PATH_WAS_SET=0
    ORIGINAL_TMUX_PATH=""
  fi
}

# Restore the pre-test tmux PATH state, including the "unset" state.
restore_tmux_path() {
  if [ "$ORIGINAL_TMUX_PATH_WAS_SET" = 1 ]; then
    tmux set-environment -g PATH "$ORIGINAL_TMUX_PATH" 2>/dev/null || true
  else
    tmux set-environment -gu PATH 2>/dev/null || true
  fi
}

# Leave no tmux session or temp transcript behind if any assertion fails.
cleanup() {
  restore_tmux_path
  agent_kill "$AGENT"
  agent_kill claude
  agent_kill codex
  agent_kill once-smoke
  agent_kill cwd-probe
  tmux kill-session -t sparctl-env-anchor 2>/dev/null || true
  rm -f "$OUT_FILE"
  rm -f "$DELTA_FILE"
  rm -f "$WATCH_FILE"
  rm -f "$ONCE_FILE"
  rm -rf "$PATH_SHIM_DIR"
  rm -rf "$STALE_PATH_SHIM_DIR"
  rm -rf "$CWD_PROBE_DIR"
  rm -f "$ONCE_CLI"
  "$TMUX_BIN" -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "SPARCTL_SMOKE_FAIL: $1" >&2; exit 1; }

# Start a persistent session and verify the wrapper reports the tmux session name.
start_output="$($ROOT/bin/sparctl start "$AGENT" "$ROOT/bin/mock-agent.sh $AGENT")"
printf '%s' "$start_output" | grep -q "tmux attach -t spar-$AGENT" \
  || fail "start output did not show how to attach"
sleep 1
agent_running "$AGENT" || fail "persistent session did not start"

# A second persistent start must not destroy a human-owned session unless explicitly requested.
if $ROOT/bin/sparctl start "$AGENT" "$ROOT/bin/mock-agent.sh $AGENT" >/dev/null 2>&1; then
  fail "start silently replaced an existing persistent session"
fi
$ROOT/bin/sparctl start --replace "$AGENT" "$ROOT/bin/mock-agent.sh $AGENT" >/dev/null
sleep 1
agent_running "$AGENT" || fail "--replace did not restart the persistent session"

# The replace flag is accepted after the agent name too, matching common CLI muscle memory.
$ROOT/bin/sparctl start "$AGENT" --replace "$ROOT/bin/mock-agent.sh $AGENT" >/dev/null
sleep 1
agent_running "$AGENT" || fail "post-name --replace did not restart the persistent session"

# Ask through the persistent session and verify the cleaned answer is still readable.
reply="$($ROOT/bin/sparctl ask "$AGENT" "$TASK")"
printf '%s' "$reply" | grep -q "\[$AGENT\] on: $TASK" \
  || fail "ask output did not include the mock answer"
printf '%s' "$reply" | grep -q "verdict:" \
  || fail "ask output was truncated before the verdict"

# Delta mode should save only the new reply rows, not the whole old session transcript.
$ROOT/bin/sparctl ask-delta "$AGENT" "delta smoke" "$DELTA_FILE" >/dev/null
[ -s "$DELTA_FILE" ] || fail "ask-delta did not write a delta file"
grep -q "\[$AGENT\] on: delta smoke" "$DELTA_FILE" \
  || fail "ask-delta output did not contain the new answer"
grep -q "\[$AGENT\] on: $TASK" "$DELTA_FILE" \
  && fail "ask-delta leaked the previous reply into the new delta"

# Watch mode should spool changes while waiting and produce a readable file for long replies.
$ROOT/bin/sparctl ask-watch "$AGENT" "watch smoke" "$WATCH_FILE" >/dev/null
[ -s "$WATCH_FILE" ] || fail "ask-watch did not write a watched transcript"
grep -q "\[$AGENT\] on: watch smoke" "$WATCH_FILE" \
  || fail "ask-watch output did not contain the watched answer"

# One-shot mode should pass the prompt as an initial CLI argument for Codex-like TUIs.
cat > "$ONCE_CLI" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="${1:-}"
printf '[once-smoke] on: %s\n' "$prompt"
printf '  verdict: one-shot prompt received\n'
sleep 30
EOF
chmod +x "$ONCE_CLI"
$ROOT/bin/sparctl ask-once once-smoke "$ONCE_CLI" "one shot smoke" "$ONCE_FILE" >/dev/null
[ -s "$ONCE_FILE" ] || fail "ask-once did not write a transcript"
grep -q "\[once-smoke\] on: one shot smoke" "$ONCE_FILE" \
  || fail "ask-once output did not contain the initial prompt answer"
$ROOT/bin/sparctl stop once-smoke

# Export a transcript file; this is the long-answer escape hatch for paging/searching later.
$ROOT/bin/sparctl transcript "$AGENT" "$OUT_FILE" >/dev/null
[ -s "$OUT_FILE" ] || fail "transcript file was not written"
grep -q "\[$AGENT\] on: $TASK" "$OUT_FILE" \
  || fail "transcript file did not contain the answer"

# List and stop commands make the persistent lifecycle explicit and scriptable.
$ROOT/bin/sparctl sessions | grep -q "spar-$AGENT" \
  || fail "sessions output did not include the persistent agent"
$ROOT/bin/sparctl stop "$AGENT"
if agent_running "$AGENT"; then
  fail "stop did not tear down the persistent session"
fi

# Known names should resolve to matching CLI commands without a second command argument.
mkdir -p "$PATH_SHIM_DIR"
mkdir -p "$STALE_PATH_SHIM_DIR"
tmux new-session -d -s sparctl-env-anchor 'sleep 30'
remember_tmux_path
tmux set-environment -g PATH "original-tmux-path-sentinel"
for known_agent in claude codex; do
  cat > "$STALE_PATH_SHIM_DIR/$known_agent" <<EOF
#!/usr/bin/env bash
exec "$ROOT/bin/mock-agent.sh" stale-$known_agent
EOF
  chmod +x "$STALE_PATH_SHIM_DIR/$known_agent"
  cat > "$PATH_SHIM_DIR/$known_agent" <<EOF
#!/usr/bin/env bash
exec "$ROOT/bin/mock-agent.sh" $known_agent
EOF
  chmod +x "$PATH_SHIM_DIR/$known_agent"
  tmux set-environment -g PATH "$STALE_PATH_SHIM_DIR:$ORIGINAL_PATH"
  PATH="$PATH_SHIM_DIR:$PATH" $ROOT/bin/sparctl start "$known_agent" >/dev/null
  sleep 1
  agent_running "$known_agent" || fail "start $known_agent did not resolve the command automatically"
  screen="$($ROOT/bin/sparctl screen "$known_agent")"
  printf '%s' "$screen" | grep -q "╭─ $known_agent online ─╮" \
    || fail "start $known_agent used stale tmux PATH instead of current PATH resolution"
  $ROOT/bin/sparctl stop "$known_agent"
done
tmux set-environment -g PATH "original-tmux-path-sentinel"
current_tmux_path="$(tmux show-environment -g PATH 2>/dev/null || true)"
[ "$current_tmux_path" = "PATH=original-tmux-path-sentinel" ] \
  || fail "tmux PATH was not restored after stale PATH regression test"
restore_tmux_path
if [ "$ORIGINAL_TMUX_PATH_WAS_SET" = 1 ]; then
  current_tmux_path="$(tmux show-environment -g PATH 2>/dev/null || true)"
  [ "$current_tmux_path" = "PATH=$ORIGINAL_TMUX_PATH" ] \
    || fail "tmux PATH restore did not preserve the pre-test value"
else
  if tmux show-environment -g PATH >/dev/null 2>&1; then
    fail "tmux PATH restore left a global override that was absent before the test"
  fi
fi

# Persistent agents must start in the caller's working directory, not in the sparring repo.
mkdir -p "$CWD_PROBE_DIR"
(
  cd "$CWD_PROBE_DIR"
  $ROOT/bin/sparctl start cwd-probe "bash -lc 'printf \"cwd:%s\\n\" \"\$PWD\"; sleep 30'" >/dev/null
)
sleep 1
screen="$($ROOT/bin/sparctl screen cwd-probe)"
printf '%s' "$screen" | grep -q "cwd:$CWD_PROBE_DIR" \
  || fail "persistent session did not start in the caller working directory"
$ROOT/bin/sparctl stop cwd-probe

echo "SPARCTL_SMOKE_OK: persistent start -> ask -> transcript -> sessions -> stop verified"

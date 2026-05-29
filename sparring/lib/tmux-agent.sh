#!/usr/bin/env bash
# tmux-agent.sh — core primitives for driving live interactive CLI agents inside tmux panes.
#
# Table of contents (key constructs):
#   Constants:
#     SPAR_SESSION_PREFIX   tmux session name namespace for spawned agents
#     PANE_WIDTH/PANE_HEIGHT fixed pane geometry for deterministic screen capture
#     POLL_INTERVAL         seconds between idle-detection samples
#     WAIT_MIN_POLLS        minimum samples before accepting idle after a send
#     STABLE_SAMPLES        consecutive identical samples that mean "agent finished"
#     GRACE_SAMPLES         initial samples ignored so we don't catch the pre-work screen
#     WAIT_TIMEOUT          hard cap (seconds) on waiting for an agent to go idle
#     SPAR_AUTO_SETTLE_SECONDS pause after fallback spawn before first send
#     CAPTURE_HISTORY       how many scrollback lines to pull when collecting a reply
#     TMUX_HISTORY_LIMIT    retained tmux scrollback for long interactive sessions
#     AGENT_START_DIRECTORY directory where spawned tmux sessions should start
#     SPAR_REPLACE_SESSION  explicit opt-in for replacing an existing tmux session
#   Functions:
#     agent_session_name public tmux session id for attach/listing output
#     agent_spawn      launch a full interactive agent in a detached tmux session
#     agent_send       "type" a single line into the agent's input box and submit it
#     agent_snapshot   render the visible pane to plain text (tmux already strips ANSI)
#     agent_wait_idle  block until the agent's screen stabilises (the real "done" signal)
#     agent_linecount  scrollback line count, used as a baseline before sending
#     agent_collect    pull everything the agent printed after a baseline line count
#     agent_transcript full retained scrollback for long answers and later reading
#     agent_save_transcript write retained scrollback to a caller-provided file path
#     strip_echo       clean a collected reply: drop the echoed prompt and blank lines
#     agent_running    check whether an agent's session is still alive
#     agent_kill       tear down a single agent session
#
# Design note: an idle interactive TUI cannot be "pushed" to from outside, so completion
# is detected by polling the rendered screen until it stops changing. This is the single
# most fragile piece of the whole approach and is deliberately isolated here.

# --- Configuration constants (no magic numbers scattered in logic) -----------------
SPAR_SESSION_PREFIX="${SPAR_SESSION_PREFIX:-spar}"   # all our sessions share this prefix
PANE_WIDTH="${PANE_WIDTH:-120}"                      # wide enough that replies don't wrap oddly
PANE_HEIGHT="${PANE_HEIGHT:-40}"                     # tall enough to hold a short reply on-screen
POLL_INTERVAL="${POLL_INTERVAL:-0.4}"                # sample cadence for idle detection
WAIT_MIN_POLLS="${WAIT_MIN_POLLS:-8}"                # keep a safety margin for slow first-token cases
STABLE_SAMPLES="${STABLE_SAMPLES:-4}"                # 4 * 0.4s ≈ 1.6s of no change => idle
GRACE_SAMPLES="${GRACE_SAMPLES:-2}"                  # ignore first ~0.8s (screen static before work)
WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"                   # give up after this many seconds
SPAR_AUTO_SETTLE_SECONDS="${SPAR_AUTO_SETTLE_SECONDS:-1}" # let fresh TUI prompts finish booting
CAPTURE_HISTORY="${CAPTURE_HISTORY:--600}"           # scrollback depth for reply collection
TMUX_HISTORY_LIMIT="${TMUX_HISTORY_LIMIT:-200000}"   # retained rows for persistent sessions
AGENT_START_DIRECTORY="${AGENT_START_DIRECTORY:-$PWD}" # default to caller's current workspace
SPAR_REPLACE_SESSION="${SPAR_REPLACE_SESSION:-0}"      # persistent starts are safe by default

# --- Internal helpers ---------------------------------------------------------------

# Map a friendly agent name to its namespaced tmux session id.
_agent_session() {
  printf '%s-%s' "$SPAR_SESSION_PREFIX" "$1"
}

# Public wrapper for scripts that need to show a human the tmux attach target.
agent_session_name() {
  _agent_session "$1"
}

# Stable fingerprint of a chunk of text, used to tell "screen changed" from "screen settled".
_hash() {
  cksum
}

# Effective idle floor keeps GRACE_SAMPLES meaningful even when WAIT_MIN_POLLS is customized.
agent_idle_floor() {
  local idle_floor="$WAIT_MIN_POLLS"
  if [ "$GRACE_SAMPLES" -ge "$idle_floor" ]; then
    idle_floor=$((GRACE_SAMPLES + 1))
  fi
  printf '%s' "$idle_floor"
}

# Shared idle readiness predicate used by normal waits and watch-mode capture.
agent_idle_ready() {
  local polls="$1" stable="$2" idle_floor
  idle_floor="$(agent_idle_floor)"
  [ "$polls" -ge "$idle_floor" ] && [ "$stable" -ge "$STABLE_SAMPLES" ]
}

# --- Public API ---------------------------------------------------------------------

# agent_spawn <name> <command...>
# Launch a full interactive agent (mock or real `claude`) in a detached tmux session.
# The pane keeps a fixed geometry so capture output is predictable across agents.
agent_spawn() {
  local name="$1"; shift
  local cmd="$*"
  # Fail fast: a spawn with no command is a programming error, not something to paper over.
  if [ -z "$name" ] || [ -z "$cmd" ]; then
    echo "SPAR_SPAWN_BAD_ARGS: agent_spawn needs <name> and <command>; got name='$name' cmd='$cmd'" >&2
    return 1
  fi
  local sess; sess="$(_agent_session "$name")"
  # Persistent sessions can contain human work, so replacement must be explicit.
  if tmux has-session -t "$sess" 2>/dev/null; then
    if [ "$SPAR_REPLACE_SESSION" != "1" ]; then
      echo "SPAR_SPAWN_SESSION_EXISTS: tmux session '$sess' already exists; stop it first or use --replace" >&2
      return 1
    fi
    tmux kill-session -t "$sess" 2>/dev/null
  fi
  # Start inside the caller's workspace and pin PATH from the current shell, not stale tmux state.
  if ! tmux new-session -d -s "$sess" -x "$PANE_WIDTH" -y "$PANE_HEIGHT" -c "$AGENT_START_DIRECTORY" -e "PATH=$PATH" "$cmd"; then
    echo "SPAR_SPAWN_FAILED: could not start tmux session '$sess' for command: $cmd" >&2
    return 1
  fi
  # Persistent work needs deep scrollback; without this, long answers disappear before export.
  if ! tmux set-option -t "$sess" history-limit "$TMUX_HISTORY_LIMIT" >/dev/null; then
    agent_kill "$name"
    echo "SPAR_HISTORY_LIMIT_FAILED: could not set history-limit for tmux session '$sess'" >&2
    return 1
  fi
}

# agent_send <name> <text>
# Deliver a single line of input to the agent exactly as if a human typed it and pressed Enter.
# Note: this sends ONE line. Multi-line prompts would submit at the first newline in a readline
# box, so callers must flatten multi-line content before sending (see README, "known limits").
agent_send() {
  local name="$1" text="$2" sess
  sess="$(_agent_session "$name")"
  if ! agent_running "$name"; then
    echo "SPAR_SEND_NO_SESSION: agent '$name' is not running; cannot deliver input" >&2
    return 1
  fi
  # -l sends the text literally (no key-name interpretation); Enter is sent as a separate keypress.
  tmux send-keys -t "$sess" -l -- "$text"
  tmux send-keys -t "$sess" Enter
}

# agent_snapshot <name>
# The visible pane rendered to plain text. tmux interprets ANSI/escape codes for us, so this is
# already free of colour codes and spinner escape sequences — only the final rendered glyphs remain.
agent_snapshot() {
  tmux capture-pane -t "$(_agent_session "$1")" -p
}

# agent_wait_idle <name>
# Block until the agent stops drawing to its screen, i.e. it has finished answering.
# This is the substitute for a real "response complete" event, which interactive TUIs do not emit.
agent_wait_idle() {
  local name="$1"
  local prev="" cur="" stable=0 polls=0 start=$SECONDS
  while :; do
    cur="$(agent_snapshot "$name" | _hash)"
    polls=$((polls + 1))
    # Count consecutive unchanged samples; any change resets the streak.
    if [ "$cur" = "$prev" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    prev="$cur"
    # Accept "idle" only after both configured floors, so static pre-work never counts.
    if agent_idle_ready "$polls" "$stable"; then
      return 0
    fi
    # Hard timeout: never hang forever on a wedged or crashed agent.
    if [ $((SECONDS - start)) -ge "$WAIT_TIMEOUT" ]; then
      echo "SPAR_WAIT_TIMEOUT: agent '$name' did not go idle within ${WAIT_TIMEOUT}s" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# _content_lines <name>
# Non-blank lines of the pane's scrollback, carriage-returns normalised. We count CONTENT
# lines (not raw pane rows) because a small reply fills pre-existing blank rows without
# growing the raw row count — so a raw line-count delta would always read as zero.
_content_lines() {
  tmux capture-pane -t "$(_agent_session "$1")" -p -S "$CAPTURE_HISTORY" \
    | sed -E 's/\r//g' \
    | grep -v -E '^[[:space:]]*$'
}

# agent_linecount <name>
# Count of content lines right now, EXCLUDING a trailing lone-prompt line. Captured before
# sending so we can later collect only the lines that appeared in response. The exclusion is
# essential: the empty input prompt ("›") sits on its own content line, and the next send
# mutates that same line into the echoed input rather than appending below it. If we counted
# it, agent_collect would skip the first (or only) echo line and leak wrapped remnants.
agent_linecount() {
  _content_lines "$1" | awk '
    { lines[NR] = $0 }
    END {
      n = NR
      # Drop a trailing line that is just the prompt glyph; it will become the echo on next send.
      if (n > 0 && lines[n] ~ /^[[:space:]]*›[[:space:]]*$/) n--
      print n
    }
  '
}

# agent_collect <name> <baseline_lines>
# Content lines that appeared after the given baseline: the agent's reply plus the echoed
# input and any trailing prompt. Cleaning is left to strip_echo so this stays agent-agnostic.
agent_collect() {
  local name="$1" base="$2"
  _content_lines "$name" | tail -n +"$((base + 1))"
}

# agent_transcript <name>
# Full retained pane history, preserving blank lines and joining wrapped terminal rows where tmux
# can prove they are continuations. This is intended for long answers that are awkward to read
# through the visible pane or the short cleaned delta used by agent_collect.
agent_transcript() {
  local name="$1"
  if ! agent_running "$name"; then
    echo "SPAR_TRANSCRIPT_NO_SESSION: agent '$name' is not running; cannot capture transcript" >&2
    return 1
  fi
  tmux capture-pane -t "$(_agent_session "$name")" -p -S - -J | sed -E 's/\r//g'
}

# agent_save_transcript <name> <path>
# Write the retained transcript to an explicit file. The parent directory must already exist so a
# typo in an output path fails loudly instead of creating unexpected folders.
agent_save_transcript() {
  local name="$1" path="$2" parent
  if [ -z "$path" ]; then
    echo "SPAR_TRANSCRIPT_BAD_PATH: output path is required for transcript export" >&2
    return 1
  fi
  parent="$(dirname "$path")"
  if [ ! -d "$parent" ]; then
    echo "SPAR_TRANSCRIPT_PARENT_MISSING: parent directory does not exist: $parent" >&2
    return 1
  fi
  agent_transcript "$name" > "$path"
}

# strip_echo <echoed_text>
# Read a raw collected reply on stdin and emit just the agent's answer:
#   - drop the echoed input, EVEN WHEN the terminal wrapped it across several lines,
#   - drop bare prompt glyphs,
#   - drop blank lines.
#
# Why the wrap handling matters: a long single-line prompt wraps at the pane width, so the
# echo becomes N rendered lines. Terminal wrapping splits at the column boundary WITHOUT
# inserting whitespace, so concatenating the wrapped lines reproduces the sent text exactly.
# We greedily consume leading lines while their whitespace/glyph-stripped concatenation is
# still a prefix of the (likewise stripped) sent text; the first line that breaks the prefix
# is where the real answer begins. Comparison ignores whitespace and the prompt glyph so it
# also tolerates space-collapsing done by the caller (flatten) and the "> " prompt prefix.
# Implemented in awk so an empty result never trips `set -e` via a non-zero grep exit.
strip_echo() {
  local text="$1"
  awk -v t="$text" '
    function squeeze(s) { gsub(/[[:space:]]/, "", s); gsub(/›/, "", s); return s }
    BEGIN { target = squeeze(t); echo = ""; done = (target == "") }
    {
      line = $0; gsub(/\r/, "", line)
      if (!done) {
        cand = echo squeeze(line)
        # Still inside the echoed (possibly wrapped) prompt?
        if (length(cand) <= length(target) && cand == substr(target, 1, length(cand))) {
          echo = cand
          if (echo == target) done = 1   # whole echo consumed; answer starts next line
          next
        }
        done = 1                          # echo ended; this line is real answer, keep it
      }
      if (line ~ /^[[:space:]]*$/) next   # drop blank lines
      if (squeeze(line) == "") next       # drop a lone prompt glyph
      print line
    }
  '
}

# agent_running <name> -> 0 if the session exists, non-zero otherwise.
agent_running() {
  tmux has-session -t "$(_agent_session "$1")" 2>/dev/null
}

# agent_kill <name> — tear down one agent; never errors if it was already gone.
agent_kill() {
  tmux kill-session -t "$(_agent_session "$1")" 2>/dev/null || true
}

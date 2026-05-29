#!/usr/bin/env bash
# mock-agent.sh — a fake interactive CLI agent used to exercise the tmux harness
# without spending real API tokens. It looks and behaves like a tiny REPL agent:
#   - prints a banner,
#   - shows an input prompt "› ",
#   - reads ONE line of input,
#   - "thinks" with an animated spinner for a couple of seconds (so the screen
#     actually changes — this is what agent_wait_idle keys off),
#   - then prints a short, structured, persona-flavoured reply,
#   - loops; "/quit" or EOF exits.
#
# Usage: mock-agent.sh <persona-name>
# Env:   MOCK_THINK_SECONDS  how long the spinner runs (default 2)
# Env:   MOCK_REPLY_DELAY_SECONDS  quiet delay before visible work starts (default 0)
#
# Swap this out for real `claude` by setting SPAR_AGENT_CMD when running bin/spar.

set -u

# --- Config -------------------------------------------------------------------------
PERSONA="${1:-agent}"                          # identity, shown in the banner and replies
THINK_SECONDS="${MOCK_THINK_SECONDS:-2}"       # simulated work duration
REPLY_DELAY_SECONDS="${MOCK_REPLY_DELAY_SECONDS:-0}" # quiet model/network latency before output
SPINNER_FRAMES='|/-\'                          # classic spinner; changing frames => "busy"
SPINNER_TICK=0.15                              # seconds between spinner frames
PROMPT='› '                                    # input prompt glyph the harness recognises

# Test configuration must be explicit integers; invalid timing values should fail loudly.
require_non_negative_integer() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      printf 'MOCK_AGENT_BAD_INTEGER: %s must be a non-negative integer; got %s\n' "$name" "$value" >&2
      exit 1
      ;;
  esac
}

require_non_negative_integer MOCK_THINK_SECONDS "$THINK_SECONDS"
require_non_negative_integer MOCK_REPLY_DELAY_SECONDS "$REPLY_DELAY_SECONDS"

# --- Banner -------------------------------------------------------------------------
printf '╭─ %s online ─╮\n' "$PERSONA"
printf 'give me a task; /quit to exit\n\n'

# --- REPL ---------------------------------------------------------------------------
while :; do
  # Draw the prompt and read a single line. In a tmux pty the typed input echoes here.
  printf '%s' "$PROMPT"
  IFS= read -r line || { printf '\n'; break; }

  # Ignore empty submissions; honour an explicit quit.
  [ -z "$line" ] && continue
  if [ "$line" = "/quit" ]; then
    printf '%s signing off\n' "$PERSONA"
    break
  fi

  # Real CLIs can stay visually static while the model/network prepares the first token.
  [ "$REPLY_DELAY_SECONDS" -gt 0 ] && sleep "$REPLY_DELAY_SECONDS"

  # Simulate work: animate the spinner until the think-budget elapses. The constantly
  # changing line keeps the screen "unstable" so the harness knows the agent is busy.
  i=0
  end=$((SECONDS + THINK_SECONDS))
  while [ "$SECONDS" -lt "$end" ]; do
    printf '\r%s thinking %s' "$PERSONA" "${SPINNER_FRAMES:i++%4:1}"
    sleep "$SPINNER_TICK"
  done
  printf '\r\033[K'   # clear the spinner line so the rendered screen is clean

  # Deterministic, persona-flavoured reply. Each persona "leans" a different way so two
  # competitors produce visibly different output — the whole point of the demo.
  case "$PERSONA" in
    alice) lean="favours shipping fast and iterating" ;;
    bob)   lean="favours hardening and edge cases first" ;;
    *)     lean="stays balanced" ;;
  esac

  # Echo the task back, but truncated — a real agent summarises rather than quoting verbatim,
  # and an untruncated echo of a long cross-review prompt would dominate the output.
  ECHO_MAX=64
  short="${line:0:ECHO_MAX}"
  [ "${#line}" -gt "$ECHO_MAX" ] && short="${short}…"

  # Structured multi-line answer so collected replies look like a real review/plan.
  printf '[%s] on: %s\n' "$PERSONA" "$short"
  printf '  - step 1: scope the smallest correct version (%s)\n' "$lean"
  printf '  - step 2: name the one risk most likely to bite\n'
  printf '  - step 3: define how we verify it actually works\n'
  printf '  verdict: %s would commit, with the risk tracked\n\n' "$PERSONA"
done

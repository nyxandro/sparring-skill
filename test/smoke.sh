#!/usr/bin/env bash
# smoke.sh — risk-based smoke test for the fragile core of Sparring.
#
# It does NOT test cosmetics. It verifies the one thing that, if broken, makes the whole
# approach worthless: can we spawn a live interactive agent, type into it, reliably detect
# that it finished, and read back exactly what it said?
#
# Exit 0 = harness works; non-zero = the idle detector or capture path regressed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/tmux-agent.sh
source "$ROOT/lib/tmux-agent.sh"

# Use a short think time so the test is quick but the spinner still animates.
export MOCK_THINK_SECONDS=1

AGENT="smoke"
DELAYED_AGENT="smoke-delayed"
TASK="ping the harness"
DELAYED_TASK="ping after quiet delay"

# Guarantee teardown regardless of outcome.
cleanup() { agent_kill "$AGENT"; agent_kill "$DELAYED_AGENT"; }
trap cleanup EXIT

fail() { echo "SMOKE_FAIL: $1" >&2; exit 1; }

# 1. Spawn a mock agent in a live tmux session.
agent_spawn "$AGENT" "$ROOT/bin/mock-agent.sh $AGENT" || fail "could not spawn agent"
sleep 1
agent_running "$AGENT" || fail "session did not come up"

# 2. Type a task, wait for the idle detector, collect the reply.
base="$(agent_linecount "$AGENT")"
agent_send "$AGENT" "$TASK" || fail "send failed"
agent_wait_idle "$AGENT" || fail "agent never went idle (idle detector regressed)"
reply="$(agent_collect "$AGENT" "$base" | strip_echo "$TASK")"

# 3. Assert the reply is the agent's structured answer, not the echoed prompt or noise.
echo "--- collected reply ---"
printf '%s\n' "$reply"
echo "-----------------------"

printf '%s' "$reply" | grep -q "\[$AGENT\] on: $TASK" \
  || fail "reply missing the agent's answer header (capture/clean regressed)"
printf '%s' "$reply" | grep -q "verdict:" \
  || fail "reply missing the verdict line (truncated capture?)"
printf '%s' "$reply" | grep -qx "$TASK" \
  && fail "echoed prompt leaked into the cleaned reply (strip_echo regressed)"

# 4. A real model can be silent before the first token; the idle detector must not stop early.
agent_spawn "$DELAYED_AGENT" "env MOCK_THINK_SECONDS=1 MOCK_REPLY_DELAY_SECONDS=2 $ROOT/bin/mock-agent.sh $DELAYED_AGENT" \
  || fail "could not spawn delayed agent"
sleep 1
delayed_base="$(agent_linecount "$DELAYED_AGENT")"
agent_send "$DELAYED_AGENT" "$DELAYED_TASK" || fail "delayed send failed"
agent_wait_idle "$DELAYED_AGENT" || fail "delayed agent never went idle"
delayed_reply="$(agent_collect "$DELAYED_AGENT" "$delayed_base" | strip_echo "$DELAYED_TASK")"
printf '%s' "$delayed_reply" | grep -q "\[$DELAYED_AGENT\] on: $DELAYED_TASK" \
  || fail "idle detector returned before the delayed answer appeared"

echo "SMOKE_OK: spawn -> send -> wait_idle -> collect all verified"

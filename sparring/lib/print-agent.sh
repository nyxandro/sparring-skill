#!/usr/bin/env bash
# print-agent.sh - non-interactive native-session providers for sparring opponents.
#
# Table of contents:
#   Constants:
#     SPAR_PRINT_TIMEOUT hard cap for non-interactive provider calls
#   Functions:
#     print_agent_session_run start or resume one provider-native session

# --- Configuration constants --------------------------------------------------------
SPAR_PRINT_TIMEOUT="${SPAR_PRINT_TIMEOUT:-500}" # seconds per provider call

# --- Internal helpers ---------------------------------------------------------------

_print_require_parent() {
  local path="$1" code="$2" parent
  parent="$(dirname "$path")"
  if [ ! -d "$parent" ]; then
    echo "$code: parent directory does not exist: $parent" >&2
    return 1
  fi
}

_print_make_tmp_for_output() {
  local path="$1" parent base
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  mktemp "$parent/.${base}.XXXXXX"
}

_print_commit_answer() {
  local tmp="$1" out="$2" provider="$3"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "SPAR_PRINT_EMPTY_ANSWER: $provider exited successfully but produced an empty answer" >&2
    return 1
  fi
  mv "$tmp" "$out"
}

_print_report_provider_failure() {
  local code="$1" detail="$2" status="$3" tmp="$4" err="$5"
  rm -f "$tmp"
  echo "$code: $detail failed with exit status $status. Inspect provider stderr below and rerun after fixing the CLI/auth/config issue." >&2
  if [ -s "$err" ]; then
    echo "SPAR_PRINT_PROVIDER_STDERR_BEGIN" >&2
    while IFS= read -r line; do
      printf '%s\n' "$line" >&2
    done < "$err"
    echo "SPAR_PRINT_PROVIDER_STDERR_END" >&2
  else
    echo "SPAR_PRINT_PROVIDER_STDERR_EMPTY: provider produced no stderr" >&2
  fi
  rm -f "$err"
  return 1
}

_print_require_timeout() {
  if ! command -v timeout >/dev/null 2>&1; then
    echo "SPAR_PRINT_TIMEOUT_COMMAND_MISSING: GNU timeout is required for print providers" >&2
    return 1
  fi
}

_print_command_for_name() {
  local name="$1"
  case "$name" in
    claude|codex)
      if ! command -v "$name" >/dev/null 2>&1; then
        echo "SPAR_PRINT_COMMAND_MISSING: command not found for print provider: $name" >&2
        return 1
      fi
      command -v "$name"
      ;;
    *)
      echo "SPAR_PRINT_UNSUPPORTED_AGENT: no print provider is configured for agent: $name" >&2
      return 1
      ;;
  esac
}

_print_generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
    return 0
  fi
  echo "SPAR_PRINT_UUID_SOURCE_MISSING: /proc/sys/kernel/random/uuid is required for Claude native sessions" >&2
  return 1
}

_print_state_value() {
  local state="$1" key="$2"
  [ -f "$state" ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$state"
}

_print_validate_state() {
  local name="$1" state="$2" stored_provider
  stored_provider="$(_print_state_value "$state" provider)"
  if [ -n "$stored_provider" ] && [ "$stored_provider" != "$name" ]; then
    echo "SPAR_PRINT_SESSION_PROVIDER_MISMATCH: state belongs to '$stored_provider', not '$name'" >&2
    return 1
  fi
}

_print_extract_codex_session_id() {
  local events="$1"
  sed -nE 's/.*"(session_id|thread_id|conversation_id)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$events" \
    | awk 'NF { print; exit }'
}

_print_append_session_audit() {
  local name="$1" state="$2" session_id="$3" prompt="$4" out="$5"
  if [ ! -f "$state" ]; then
    {
      printf 'provider=%s\n' "$name"
      printf 'session_id=%s\n' "$session_id"
      printf 'created_at=%s\n' "$(date -Is)"
    } > "$state"
  fi
  {
    printf '\nUSER: %s\n' "$prompt"
    printf 'ASSISTANT(%s native:%s):\n' "$name" "$session_id"
    cat "$out"
    printf '\n'
  } >> "$state"
}

# --- Public API ---------------------------------------------------------------------

# print_agent_session_run <name> <state-file> <prompt> <output-file>
# Start a provider-native session on first use and resume that exact session on later turns.
print_agent_session_run() {
  local name="$1" state="$2" prompt="$3" out="$4" exe tmp err events session_id is_first_turn status
  if [ -z "$name" ] || [ -z "$state" ] || [ -z "$prompt" ] || [ -z "$out" ]; then
    echo "SPAR_PRINT_SESSION_BAD_ARGS: print_agent_session_run needs <name> <state-file> <prompt> <output-file>" >&2
    return 1
  fi
  _print_require_parent "$state" "SPAR_PRINT_SESSION_STATE_PARENT_MISSING" || return 1
  _print_require_parent "$out" "SPAR_PRINT_SESSION_OUTPUT_PARENT_MISSING" || return 1
  _print_require_timeout || return 1
  _print_validate_state "$name" "$state" || return 1
  exe="$(_print_command_for_name "$name")" || return 1
  tmp="$(_print_make_tmp_for_output "$out")"
  err="$(_print_make_tmp_for_output "$out.stderr")"
  events="$(_print_make_tmp_for_output "$out.events")"
  session_id="$(_print_state_value "$state" session_id)"
  is_first_turn=0

  case "$name" in
    claude)
      if [ -z "$session_id" ]; then
        session_id="$(_print_generate_uuid)" || { rm -f "$tmp" "$err" "$events"; return 1; }
        is_first_turn=1
      fi
      if [ "$is_first_turn" = 1 ]; then
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" -p --permission-mode plan \
          --output-format text --session-id "$session_id" > "$tmp" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_SESSION_PROVIDER_FAILED" "claude first native turn for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
      else
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" -p --permission-mode plan \
          --output-format text --resume "$session_id" > "$tmp" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_SESSION_PROVIDER_FAILED" "claude native session continuation for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
      fi
      ;;
    codex)
      if [ -z "$session_id" ]; then
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" --sandbox read-only -C "$PWD" \
          exec --skip-git-repo-check --color never --json --output-last-message "$tmp" - > "$events" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_SESSION_PROVIDER_FAILED" "codex first native turn for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
        session_id="$(_print_extract_codex_session_id "$events")"
        if [ -z "$session_id" ]; then
          rm -f "$tmp" "$err" "$events"
          echo "SPAR_PRINT_SESSION_ID_MISSING: codex --json did not emit a session/thread id" >&2
          return 1
        fi
      else
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" --sandbox read-only -C "$PWD" \
          exec --skip-git-repo-check --color never --json --output-last-message "$tmp" resume "$session_id" - > "$events" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_SESSION_PROVIDER_FAILED" "codex native session continuation for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
      fi
      ;;
  esac

  rm -f "$err"
  _print_commit_answer "$tmp" "$out" "$name" || { rm -f "$events"; return 1; }
  _print_append_session_audit "$name" "$state" "$session_id" "$prompt" "$out"
  rm -f "$events"
}

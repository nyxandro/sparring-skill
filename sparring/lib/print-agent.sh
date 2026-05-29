#!/usr/bin/env bash
# print-agent.sh — primary non-interactive providers for sparring opponents.
#
# Table of contents (key constructs):
#   Constants:
#     SPAR_PRINT_TIMEOUT       hard cap for non-interactive provider calls
#     SPAR_PRINT_CONTEXT_LINES retained session history lines sent on each turn
#   Functions:
#     _print_report_provider_failure include provider stderr in harness failure diagnostics
#     print_agent_run          run claude -p / codex exec and write the answer to a file
#     print_agent_session_run  build a rolling-history prompt, run the provider, append transcript
#     print_agent_resume_run   run provider-native resume while keeping a local audit transcript

# --- Configuration constants --------------------------------------------------------
SPAR_PRINT_TIMEOUT="${SPAR_PRINT_TIMEOUT:-300}"             # seconds per print/exec call
SPAR_PRINT_CONTEXT_LINES="${SPAR_PRINT_CONTEXT_LINES:-400}" # bounded history for next prompt

# --- Internal helpers ---------------------------------------------------------------

# Fail early when an output path has a typo; callers should create directories deliberately.
_print_require_parent() {
  local path="$1" code="$2" parent
  parent="$(dirname "$path")"
  if [ ! -d "$parent" ]; then
    echo "$code: parent directory does not exist: $parent" >&2
    return 1
  fi
}

# Create the temporary answer file next to the target so the final mv stays on one filesystem.
_print_make_tmp_for_output() {
  local path="$1" parent base
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  mktemp "$parent/.${base}.XXXXXX"
}

# A zero-byte successful answer is not useful sparring output, so treat it as provider failure.
_print_commit_answer() {
  local tmp="$1" out="$2" provider="$3"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "SPAR_PRINT_EMPTY_ANSWER: $provider exited successfully but produced an empty answer" >&2
    return 1
  fi
  mv "$tmp" "$out"
}

# Preserve provider stderr on failures; without it, transient CLI/auth/flag errors become opaque.
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

# GNU timeout keeps wedged providers from blocking the harness forever.
_print_require_timeout() {
  if ! command -v timeout >/dev/null 2>&1; then
    echo "SPAR_PRINT_TIMEOUT_COMMAND_MISSING: GNU timeout is required for print providers" >&2
    return 1
  fi
}

# Resolve a supported non-interactive provider in the caller's current PATH.
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

# Linux exposes a kernel UUID source, avoiding an extra uuidgen dependency in the harness.
_print_generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
    return 0
  fi
  echo "SPAR_PRINT_UUID_SOURCE_MISSING: /proc/sys/kernel/random/uuid is required for Claude native resume" >&2
  return 1
}

# Read a simple key=value field from the native resume audit file.
_print_resume_state_value() {
  local state="$1" key="$2"
  [ -f "$state" ] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$state"
}

# Native resume state is provider-specific; mixing providers would resume the wrong CLI session.
_print_resume_validate_state() {
  local name="$1" state="$2" stored_provider
  stored_provider="$(_print_resume_state_value "$state" provider)"
  if [ -n "$stored_provider" ] && [ "$stored_provider" != "$name" ]; then
    echo "SPAR_PRINT_RESUME_PROVIDER_MISMATCH: state belongs to '$stored_provider', not '$name'" >&2
    return 1
  fi
}

# Extract the first known Codex session identifier from JSONL emitted by `codex exec --json`.
_print_extract_codex_session_id() {
  local events="$1"
  sed -nE 's/.*"(session_id|thread_id|conversation_id)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$events" \
    | awk 'NF { print; exit }'
}

# Append/update local audit state after a successful provider-native turn.
_print_append_resume_audit() {
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

# print_agent_run <name> <prompt> <output-file>
# Prefer deterministic stdout-style providers over TUI scraping. The answer is written atomically
# only after the provider exits successfully, so failed calls never leave misleading output behind.
print_agent_run() {
  local name="$1" prompt="$2" out="$3" exe tmp err status
  if [ -z "$name" ] || [ -z "$prompt" ] || [ -z "$out" ]; then
    echo "SPAR_PRINT_BAD_ARGS: print_agent_run needs <name> <prompt> <output-file>" >&2
    return 1
  fi
  _print_require_parent "$out" "SPAR_PRINT_PARENT_MISSING" || return 1
  _print_require_timeout || return 1
  exe="$(_print_command_for_name "$name")" || return 1
  tmp="$(_print_make_tmp_for_output "$out")"
  err="$(_print_make_tmp_for_output "$out.stderr")"

  # Providers are intentionally explicit and receive prompts through stdin to avoid ARG_MAX/ps leaks.
  case "$name" in
    claude)
      if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" -p --permission-mode plan --output-format text > "$tmp" 2> "$err"; then
        :
      else
        status=$?
        _print_report_provider_failure "SPAR_PRINT_PROVIDER_FAILED" "claude -p for agent '$name'" "$status" "$tmp" "$err"
        return 1
      fi
      ;;
    codex)
      if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" exec --sandbox read-only --skip-git-repo-check \
        --color never -C "$PWD" --output-last-message "$tmp" - >/dev/null 2> "$err"; then
        :
      else
        status=$?
        _print_report_provider_failure "SPAR_PRINT_PROVIDER_FAILED" "codex exec for agent '$name'" "$status" "$tmp" "$err"
        return 1
      fi
      ;;
  esac

  rm -f "$err"
  _print_commit_answer "$tmp" "$out" "$name"
}

# print_agent_session_run <name> <session-file> <prompt> <output-file>
# Keep dialogue state in a simple append-only transcript and send a bounded rolling context to the
# provider. This gives print/exec mode conversational continuity without relying on CLI internals.
print_agent_session_run() {
  local name="$1" session="$2" prompt="$3" out="$4" built_prompt
  if [ -z "$name" ] || [ -z "$session" ] || [ -z "$prompt" ] || [ -z "$out" ]; then
    echo "SPAR_PRINT_SESSION_BAD_ARGS: print_agent_session_run needs <name> <session-file> <prompt> <output-file>" >&2
    return 1
  fi
  _print_require_parent "$session" "SPAR_PRINT_SESSION_PARENT_MISSING" || return 1
  _print_require_parent "$out" "SPAR_PRINT_SESSION_OUTPUT_PARENT_MISSING" || return 1

  # The prompt is self-contained: previous sparring turns plus the new request and response rules.
  built_prompt="$({
    printf 'Ты участвуешь в sparring-сессии как независимый инженер.\n'
    printf 'Учитывай историю ниже, но отвечай только на новый запрос. Не редактируй файлы без явной просьбы.\n\n'
    printf 'История sparring-сессии:\n'
    if [ -f "$session" ]; then
      tail -n "$SPAR_PRINT_CONTEXT_LINES" "$session"
    else
      printf '(истории пока нет)\n'
    fi
    printf '\nНовый запрос пользователя:\n%s\n' "$prompt"
  })"

  print_agent_run "$name" "$built_prompt" "$out" || return 1
  {
    printf '\nUSER: %s\n' "$prompt"
    printf 'ASSISTANT(%s):\n' "$name"
    cat "$out"
    printf '\n'
  } >> "$session"
}

# print_agent_resume_run <name> <state-file> <prompt> <output-file>
# Use the provider's own persisted conversation instead of replaying transcript text. The state file
# stores only the provider session id plus an audit transcript for humans and future debugging.
print_agent_resume_run() {
  local name="$1" state="$2" prompt="$3" out="$4" exe tmp err events session_id is_first_turn status
  if [ -z "$name" ] || [ -z "$state" ] || [ -z "$prompt" ] || [ -z "$out" ]; then
    echo "SPAR_PRINT_RESUME_BAD_ARGS: print_agent_resume_run needs <name> <state-file> <prompt> <output-file>" >&2
    return 1
  fi
  _print_require_parent "$state" "SPAR_PRINT_RESUME_STATE_PARENT_MISSING" || return 1
  _print_require_parent "$out" "SPAR_PRINT_RESUME_OUTPUT_PARENT_MISSING" || return 1
  _print_require_timeout || return 1
  _print_resume_validate_state "$name" "$state" || return 1
  exe="$(_print_command_for_name "$name")" || return 1
  tmp="$(_print_make_tmp_for_output "$out")"
  err="$(_print_make_tmp_for_output "$out.stderr")"
  events="$(_print_make_tmp_for_output "$out.events")"
  session_id="$(_print_resume_state_value "$state" session_id)"
  is_first_turn=0

  # Claude can start with a caller-chosen UUID, so no JSON parsing is needed for the first turn.
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
          _print_report_provider_failure "SPAR_PRINT_RESUME_PROVIDER_FAILED" "claude first native turn for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
      else
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" -p --permission-mode plan \
          --output-format text --resume "$session_id" > "$tmp" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_RESUME_PROVIDER_FAILED" "claude native resume for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
      fi
      ;;
    codex)
      if [ -z "$session_id" ]; then
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" --sandbox read-only \
          -C "$PWD" exec --skip-git-repo-check --color never --json --output-last-message "$tmp" - > "$events" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_RESUME_PROVIDER_FAILED" "codex first native turn for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
        session_id="$(_print_extract_codex_session_id "$events")"
        if [ -z "$session_id" ]; then
          rm -f "$tmp" "$err" "$events"
          echo "SPAR_PRINT_RESUME_SESSION_ID_MISSING: codex --json did not emit a session/thread id" >&2
          return 1
        fi
      else
        if printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" --sandbox read-only \
          -C "$PWD" exec resume --skip-git-repo-check --json --output-last-message "$tmp" "$session_id" - > "$events" 2> "$err"; then
          :
        else
          status=$?
          rm -f "$events"
          _print_report_provider_failure "SPAR_PRINT_RESUME_PROVIDER_FAILED" "codex native resume for agent '$name'" "$status" "$tmp" "$err"
          return 1
        fi
      fi
      ;;
  esac

  rm -f "$err"
  _print_commit_answer "$tmp" "$out" "$name" || { rm -f "$events"; return 1; }
  _print_append_resume_audit "$name" "$state" "$session_id" "$prompt" "$out"
  rm -f "$events"
}

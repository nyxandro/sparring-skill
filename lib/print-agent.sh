#!/usr/bin/env bash
# print-agent.sh — primary non-interactive providers for sparring opponents.
#
# Table of contents (key constructs):
#   Constants:
#     SPAR_PRINT_TIMEOUT       hard cap for non-interactive provider calls
#     SPAR_PRINT_CONTEXT_LINES retained session history lines sent on each turn
#   Functions:
#     print_agent_run          run claude -p / codex exec and write the answer to a file
#     print_agent_session_run  build a rolling-history prompt, run the provider, append transcript

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

# --- Public API ---------------------------------------------------------------------

# print_agent_run <name> <prompt> <output-file>
# Prefer deterministic stdout-style providers over TUI scraping. The answer is written atomically
# only after the provider exits successfully, so failed calls never leave misleading output behind.
print_agent_run() {
  local name="$1" prompt="$2" out="$3" exe tmp
  if [ -z "$name" ] || [ -z "$prompt" ] || [ -z "$out" ]; then
    echo "SPAR_PRINT_BAD_ARGS: print_agent_run needs <name> <prompt> <output-file>" >&2
    return 1
  fi
  _print_require_parent "$out" "SPAR_PRINT_PARENT_MISSING" || return 1
  _print_require_timeout || return 1
  exe="$(_print_command_for_name "$name")" || return 1
  tmp="$(_print_make_tmp_for_output "$out")"

  # Providers are intentionally explicit and receive prompts through stdin to avoid ARG_MAX/ps leaks.
  case "$name" in
    claude)
      if ! printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" -p --permission-mode plan --output-format text > "$tmp"; then
        rm -f "$tmp"
        echo "SPAR_PRINT_PROVIDER_FAILED: claude -p failed for agent '$name'" >&2
        return 1
      fi
      ;;
    codex)
      if ! printf '%s' "$prompt" | timeout "$SPAR_PRINT_TIMEOUT" "$exe" exec --sandbox read-only --skip-git-repo-check \
        --color never -C "$PWD" --output-last-message "$tmp" - >/dev/null; then
        rm -f "$tmp"
        echo "SPAR_PRINT_PROVIDER_FAILED: codex exec failed for agent '$name'" >&2
        return 1
      fi
      ;;
  esac

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

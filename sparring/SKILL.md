---
name: sparring
description: Use when the user says "sparring" or asks to run a sparring session with Claude, GPT-5, Codex, or another CLI agent for planning, brainstorming, second opinions, code review, architecture critique, or normal dialogue. This skill prefers non-interactive print providers (`claude -p`, `codex exec`), can continue provider-native sessions with `ask-resume`, falls back to tmux live sessions when needed, and incorporates the opponent's answer into the final response.
---

# Sparring

Use this skill when the user wants a `sparring` session with another CLI agent. The skill turns requests like “run sparring with Claude”, “sparring my plan with Codex”, or “discuss this with Claude” into a concrete workflow through the bundled `sparring` harness.

Production rule: prefer print/exec mode first. Use `ask-resume` for multi-turn sparring when provider-native continuity matters; use `ask-session` when portable transcript replay is preferred. Use tmux only as a fallback or when the user explicitly wants a live attachable TUI session.

## Trigger Phrases

Use this skill for requests containing `sparring`, especially:

- `run sparring with Claude`
- `do sparring with Claude`
- `do sparring with GPT-5`
- `sparring with Codex`
- `start sparring and leave the session running`
- `give me the sparring transcript`
- `read the long sparring answer`
- `sparring my plan with Claude`
- `discuss this approach with Codex`
- `get a second opinion through sparring`

Do not use this skill for ordinary non-interactive shell commands where stdout alone is the requested result.

## Requirements

This skill expects:

- The bundled `bin/sparctl`, `lib/print-agent.sh`, and `lib/tmux-agent.sh` files from this skill folder.
- The requested opponent CLI installed, for example `claude` or `codex`.
- `timeout` from GNU coreutils for print/exec calls.
- `tmux` only when using live/fallback mode.

Resolve the harness path in this order:

1. Use this skill's own bundled harness: `<skill directory>/bin/sparctl`.
2. If the runtime exposes a “Base directory for this skill” line, treat that directory as `<skill directory>`.
3. If you are developing the skill locally and `SPARRING_HOME` is explicitly set, it may override the bundled path for testing only.
4. If no executable bundled `bin/sparctl` exists, report `SPARRING_HARNESS_MISSING` and include the skill directory you checked.

Do not silently fall back to raw tmux when `sparctl` is missing; the harness contains the tested print/session/fallback behavior.

## Language Rule

Use the user's request language for the opponent prompt and for the final response.

If the user writes in Russian, send the opponent a Russian prompt and return Russian output. If the user writes in English, send the opponent an English prompt and return English output. If the user mixes languages, prefer the dominant language of the task.

When asking the opponent for structured output, include the language requirement explicitly:

```text
Answer in Russian because the user's original request is in Russian.
```

## Opponent Mapping

Map names as follows:

| User says | Harness name | Primary backend |
|---|---|---|
| `Claude`, `Klod`, `Klaud`, `Klad` | `claude` | `claude -p` |
| `GPT-5`, `Codex`, `Kodeks` | `codex` | `codex exec` |

Before using a provider when uncertain, check it exists:

```bash
command -v claude
command -v codex
```

If the CLI is missing, report it directly and do not substitute another agent silently.

## Preferred Harness Commands

Use the resolved bundled `sparctl` path. In examples below, `$SPARRING_HARNESS` means the executable at `<skill directory>/bin/sparctl`.

```bash
$SPARRING_HARNESS ask-print <name> "<prompt>" /tmp/<name>-print.txt
$SPARRING_HARNESS ask-session <name> /tmp/<name>-sparring.log "<prompt>" /tmp/<name>-turn.txt
$SPARRING_HARNESS ask-resume <name> /tmp/<name>-native.log "<prompt>" /tmp/<name>-turn.txt
$SPARRING_HARNESS ask-auto <name> "<prompt>" /tmp/<name>-auto.txt
```

Command meanings:

- `ask-print`: one-shot print/exec call, no tmux.
- `ask-session`: print/exec call with file-backed sparring history; use this for portable multi-turn debate.
- `ask-resume`: print/exec call with provider-native resume (`claude --resume` / `codex exec resume`) plus a local audit file; use this for continued sparring when the provider should remember its own prior turns.
- `ask-auto`: print/exec first, then tmux fallback if no print provider is configured or the print provider fails.

Run `sparctl` from the project directory that the opponent should inspect. For example, if the current task is in `/home/nyx/projects/domovey`, use that directory as the shell working directory.

Print providers receive prompts through stdin, not argv. This keeps long session prompts away from process listings and avoids shell argument-size limits. Empty successful provider answers are treated as errors by the harness.

## General Sparring Loop

Use this loop for planning, architecture discussion, brainstorming, second opinions, and review:

1. Identify the opponent from the user's wording.
2. Build a prompt in the user's language asking for an independent view, risks, alternatives and concrete recommendations. Remind the opponent to counter the common model tendency to be agreeable: their role is to test the idea critically, not to please the user or the main agent.
3. Use `ask-resume` by default for multi-turn debate so Claude/Codex continue their native provider session. Use `ask-session` instead when native resume fails, when you need provider-agnostic transcript replay, or when you do not want provider-side session persistence.
4. Read the output file and incorporate the opponent's answer into your own reasoning.
5. If you have doubts, partial disagreement, unanswered questions, or the opponent's answer feels too agreeable or too shallow, do not stop at a single second opinion. Send a follow-up turn that states your objections clearly and asks the opponent to defend, revise, or narrow their position.
6. Do not debate just for ceremony: continue only when the extra turn can change the conclusion, expose a hidden assumption, or make the recommendation more precise.
7. Delete the temporary output file after reading it unless the user explicitly asks to keep artifacts.
8. If continuing the debate, keep the same state/session file and send the next turn through it (`ask-resume` state file or `ask-session` transcript file).
9. If the sparring is finished, delete the state/session file too unless the user explicitly asks to keep it.
10. Answer the user with a synthesis: your conclusion, what the opponent added, what you challenged, and what changed because of sparring.

For a planning prompt, prefer this shape:

```text
<User task in the original language>

You are the second engineer in a sparring session. Give an independent view: strengths, risks, alternatives, and concrete improvements to the plan. Answer in the same language as the user's task. Do not edit files.

Important: models often tend to agree with and please the user or another agent. In this role, counterbalance that bias: test assumptions critically, name weak points directly, and do not agree if the position seems incomplete or wrong. At the same time, do not argue artificially when the arguments are genuinely strong.

If the main agent's next turn contains doubts or objections to your position, do not agree automatically: defend your assessment where it is strong, clarify weak spots, and state explicitly what should be reconsidered.
```

## Print-Mode Examples

Claude native resume:

```bash
$SPARRING_HARNESS ask-resume claude /tmp/claude-native.log "<prompt>" /tmp/claude-turn.txt
```

Codex native resume:

```bash
$SPARRING_HARNESS ask-resume codex /tmp/codex-native.log "<prompt>" /tmp/codex-turn.txt
```

Portable transcript replay:

```bash
$SPARRING_HARNESS ask-session claude /tmp/claude-sparring.log "<prompt>" /tmp/claude-turn.txt
$SPARRING_HARNESS ask-session codex /tmp/codex-sparring.log "<prompt>" /tmp/codex-turn.txt
```

Auto fallback:

```bash
$SPARRING_HARNESS ask-auto claude "<prompt>" /tmp/claude-auto.txt
```

## Tmux Live/Fallback Mode

Use tmux mode only when print/exec mode is unavailable, fails due limits/auth, or the user explicitly wants an attachable live session.

```bash
$SPARRING_HARNESS start [--replace] <session-name> <agent-command>
$SPARRING_HARNESS start claude
$SPARRING_HARNESS start --replace claude
$SPARRING_HARNESS send <session-name> "<single-line prompt>"
$SPARRING_HARNESS ask-delta <session-name> "<prompt>" /tmp/<session-name>-delta.txt
$SPARRING_HARNESS ask-watch <session-name> "<prompt>" /tmp/<session-name>-watch.txt
$SPARRING_HARNESS transcript <session-name> /tmp/<session-name>-transcript.txt
$SPARRING_HARNESS stop <session-name>
```

Persistent starts are safe by default: `start <name>` fails if `spar-<name>` already exists. Use `--replace` only when intentionally killing and recreating that session. If `start` reports `SPAR_SPAWN_SESSION_EXISTS`, do not retry with `--replace` automatically; ask whether the user wants to attach, stop, or replace the existing session.

Tell the user they can attach manually with:

```bash
tmux attach -t spar-<name>
```

## Long Answers

For print mode, the full answer is written directly to the output file. Read it with the file reading tool using offsets/limits if it is long.

For tmux mode, prefer `ask-watch` or `transcript` for very long answers because rendered scrollback can be noisy and bounded.

## Session Lifecycle

If using print mode, cleanup temporary output/session files after summarizing unless the user asks to keep them. This is mandatory for routine review/sparring: after reading `/tmp/<name>-turn.txt`, remove it; remove `/tmp/<name>-native.log` or `/tmp/<name>-sparring.log` when the dialogue will not continue.

If the user asks for an ongoing tmux sparring session, leave it running and report the attach command.

If the user asks for a quick tmux test, cleanup after the test:

```bash
$SPARRING_HARNESS stop <session-name>
```

## Reporting Back

Report briefly:

- Which opponent was used and which backend was launched (`ask-resume`, `ask-session`, `ask-print`, `ask-auto`, or tmux).
- Output path if a long answer was captured.
- State/session file path only if it remains useful for continued sparring.
- Whether fallback was used.
- Cleanup status for disposable files/sessions.
- How the opponent's answer changed or confirmed your own conclusion.
- Preserve the user's language in the final answer unless they explicitly ask otherwise.

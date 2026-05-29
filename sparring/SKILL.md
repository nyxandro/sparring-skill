---
name: sparring
description: Use when the user says "sparring", "run sparring with Claude", "do sparring with Claude", "do sparring with GPT-5", "sparring with Codex", "sparring my plan with Claude", "discuss this approach with Codex", "get a second opinion through sparring", "give me the sparring transcript", "read the long sparring answer", or asks to leave a sparring session running. Runs a model-vs-model sparring flow through the bundled sparctl harness for planning, brainstorming, second opinions, code review, architecture critique, or normal dialogue; uses ask-session by default for fresh sessions, ask-resume only for explicit continuation of a known provider-native state, and tmux only when explicitly needed for live sessions.
---

# Sparring

Use this skill after it has been selected for a sparring request with another CLI agent. The skill turns that request into a concrete workflow through the bundled `sparring` harness.

Production rule: for a fresh sparring session, use `ask-session` with a unique temporary session file. Use `ask-resume` only to continue a provider-native session whose state file was created and kept during the current sparring flow. Use tmux only when non-interactive CLI mode is unavailable or when the user explicitly wants a live attachable TUI session; do not use automatic fallback as the normal workflow.

## Scope

After this skill is selected, use it only for sparring-style requests with another model or CLI agent. Do not use it for ordinary non-interactive shell commands where stdout alone is the requested result.

## Requirements

This skill expects:

- The bundled `bin/sparctl`, `lib/print-agent.sh`, and `lib/tmux-agent.sh` files from this skill folder.
- The requested opponent CLI installed, for example `claude` or `codex`.
- `timeout` from GNU coreutils for non-interactive CLI calls.
- `tmux` only when using explicit live TUI mode.

Resolve the harness path in this order:

1. Use this skill's own bundled harness: `<skill directory>/bin/sparctl`.
2. If the runtime exposes a “Base directory for this skill” line, treat that directory as `<skill directory>`.
3. If you are developing the skill locally and `SPARRING_HOME` is explicitly set, it may override the bundled path for testing only.
4. If no executable bundled `bin/sparctl` exists, report `SPARRING_HARNESS_MISSING` and include the skill directory you checked.

Do not silently fall back to raw tmux when `sparctl` is missing; the harness contains the tested session, resume, and tmux behavior.

## Language Rule

Use the user's request language for the opponent prompt and for the final response.

If the user writes in Russian, send the opponent a Russian prompt and return Russian output. If the user writes in English, send the opponent an English prompt and return English output. If the user mixes languages, prefer the dominant language of the task.

When asking the opponent for structured output, include the language requirement explicitly:

```text
Answer in Russian because the user's original request is in Russian.
```

## Supported Opponent Backends

Opponent names in the user's request describe intent; harness names describe installed CLI backends. The model used behind each backend depends on that CLI's own configuration.

The bundled non-interactive providers support these CLI backends:

| Harness backend | CLI command |
|---|---|
| `claude` | `claude -p` |
| `codex` | `codex exec` |

Common wording for `claude`: Claude, Claude Code, Anthropic CLI, the Claude CLI.

Common wording for `codex`: Codex, Codex CLI, OpenAI Codex, GPT through Codex.

Do not treat backend names as model names. Claude Code, GPT-5, or another model may be configured behind an installed CLI. If the user names only a model family, do not silently choose a backend unless the request or current context clearly says which installed CLI should represent it. Ask a short clarification or use an explicitly configured harness/backend.

Before using a provider, check that the corresponding CLI exists:

```bash
command -v claude
command -v codex
```

If the CLI is missing, report it directly and do not substitute another agent silently.

## Harness Commands Used By This Skill

Use the resolved bundled `sparctl` path. In examples below, `$SPARRING_HARNESS` means the executable at `<skill directory>/bin/sparctl`.

Default command for a fresh sparring session:

```bash
$SPARRING_HARNESS ask-session <name> /tmp/<name>-sparring.log "<prompt>" /tmp/<name>-turn.txt
```

Explicit native continuation command, only when this sparring flow already created and intentionally kept the state file:

```bash
$SPARRING_HARNESS ask-resume <name> /tmp/<name>-native.log "<prompt>" /tmp/<name>-turn.txt
```

Command meanings:

- `ask-session`: non-interactive CLI call with file-backed sparring history; use this as the default for fresh multi-turn debate.
- `ask-resume`: non-interactive CLI call with provider-native resume (`claude --resume` / `codex exec resume`) plus a local audit file; use this only when intentionally continuing a known provider-native state file from the current sparring flow.

Non-interactive providers receive prompts through stdin, not argv. This keeps long session prompts away from process listings and avoids shell argument-size limits. Empty successful provider answers are treated as errors by the harness.

## General Sparring Loop

Use this loop for planning, architecture discussion, brainstorming, second opinions, code review, and normal dialogue:

1. Resolve the opponent backend from the user's wording and available CLI tools. If the user names only a model family without a clear CLI backend, ask one short clarification instead of guessing.
2. Build a prompt in the user's language asking for an independent response that follows the structured sparring protocol below. Remind the opponent to counter the common model tendency to be agreeable: their role is to test the task critically, not to please the user or the main agent.
3. Use `ask-session` by default for a fresh sparring request, with a unique temporary session file. Do not use `ask-resume` for a new sparring request or first turn: provider-native resume can continue stale CLI context if the state file already exists. Use `ask-resume` only when explicitly continuing a provider-native session state that this sparring flow created and intentionally kept.
4. Read the output file and compare the opponent's answer with your own position: what you accept, what you reject, what remains disputed, and what new questions appeared.
5. If required user data is missing, stop the sparring instead of debating on invented assumptions. Return to the user with a concise question list explaining what data is needed, why it matters, and which decisions are blocked.
6. If important disputed points remain, send a focused follow-up turn. Name the exact disagreements and ask the opponent to defend strong arguments, revise weak ones, or propose a synthesis.
7. Continue only while the next turn can improve the decision: unresolved high-impact disagreements, unchecked assumptions, outdated approach risks, important trade-offs, or shallow/over-agreeable answers.
8. Stop when the key decisions are agreed, or when remaining disagreements are clearly documented as trade-offs that cannot be resolved without external/user data.
9. Delete the temporary output file after reading it unless the user explicitly asks to keep artifacts.
10. If continuing the debate, keep the same `ask-session` transcript file and send the next turn through it. Use an `ask-resume` state file only if this sparring flow already started in native-resume mode and the user intentionally wants that provider-native continuation.
11. If the sparring is finished, delete the state/session file too unless the user explicitly asks to keep it.
12. Answer the user with a structured synthesis, not a raw transcript.

## Structured Sparring Protocol

The opponent prompt should make the opponent work in layers, not jump straight into implementation details:

1. First, fix the subject of discussion: what task was understood, what the main goal is, what constraints matter, and which assumptions are being made.
2. Then check the high-level framing: whether the right problem is being solved, whether the proposed direction is necessary, whether there is unnecessary complexity, duplicated concepts, or a simpler model.
3. Check freshness: whether the proposed approaches, patterns, libraries, APIs, and tools are current. When freshness matters and the opponent has web access, ask it to use web search or current documentation before recommending a solution.
4. Produce a list of disputed points: what should be challenged, what is weak, where alternatives exist, where trade-offs exist, and what must be decided before a final answer.
5. Only after that, answer the concrete request.

The goal is not artificial agreement. The goal is the best tested solution after criticism. If consensus is not possible, preserve the disagreement as an explicit trade-off with reasons.

For the opponent prompt, adapt this shape into the user's language:

```text
<User task in the original language>

You are the second participant in a sparring session. Do not accept the framing automatically: check whether the task is understood correctly, challenge weak assumptions, identify unnecessary complexity, and then answer the concrete request. Also check whether the proposed approaches, patterns, libraries, APIs, and tooling are current rather than outdated; when freshness matters and you have web access, use web search or current documentation before recommending a solution. Answer in the same language as the user's task. Do not edit files.

First fix the subject of discussion: restate the understood task, main goal, important constraints, and key assumptions. Then check the high-level framing, freshness of approaches/tools, and possible simplifications. After that, list the disputed points that should be challenged or decided before a final conclusion.

If required user data is missing, say exactly what is missing and why the decision is blocked. Do not invent missing data or continue on hidden assumptions.

Important: models often tend to agree with and please the user or another agent. In this role, counterbalance that bias: test assumptions critically, name weak points directly, and do not agree if the position seems incomplete, overcomplicated, outdated, or wrong. At the same time, do not argue artificially when the arguments are genuinely strong.

If the main agent's next turn contains doubts or objections to your position, do not agree automatically: defend your assessment where it is strong, clarify weak spots, and state explicitly what should be reconsidered.
```

## Non-Interactive CLI Examples

Fresh sparring session:

```bash
$SPARRING_HARNESS ask-session claude /tmp/claude-sparring.log "<prompt>" /tmp/claude-turn.txt
$SPARRING_HARNESS ask-session codex /tmp/codex-sparring.log "<prompt>" /tmp/codex-turn.txt
```

Explicit native continuation of a known Claude state file:

```bash
$SPARRING_HARNESS ask-resume claude /tmp/claude-native.log "<prompt>" /tmp/claude-turn.txt
```

Explicit native continuation of a known Codex state file:

```bash
$SPARRING_HARNESS ask-resume codex /tmp/codex-native.log "<prompt>" /tmp/codex-turn.txt
```

## Tmux Live Mode

Use tmux mode manually only when non-interactive CLI mode is unavailable, fails due limits/auth, or the user explicitly wants an attachable live session.

```bash
$SPARRING_HARNESS start [--replace] <name> <agent-command>
$SPARRING_HARNESS start claude
$SPARRING_HARNESS start --replace claude
$SPARRING_HARNESS ask-watch <name> "<prompt>" /tmp/<name>-watch.txt
$SPARRING_HARNESS transcript <name> /tmp/<name>-transcript.txt
$SPARRING_HARNESS stop <name>
```

Here `<name>` is the harness agent name, for example `claude`; the tmux session is named `spar-<name>`. Persistent starts are safe by default: `start <name>` fails if `spar-<name>` already exists. Use `--replace` only when intentionally killing and recreating that session. If `start` reports `SPAR_SPAWN_SESSION_EXISTS`, do not retry with `--replace` automatically; ask whether the user wants to attach, stop, or replace the existing session.

Tell the user they can attach manually with:

```bash
tmux attach -t spar-<name>
```

## Long Answers

For non-interactive CLI mode, the full answer is written directly to the output file. Read it with the file reading tool using offsets/limits if it is long.

For tmux mode, prefer `ask-watch` or `transcript` for very long answers because rendered scrollback can be noisy and bounded.

## Session Lifecycle

If using non-interactive CLI mode, cleanup temporary output/session files after summarizing unless the user asks to keep them. This is mandatory for routine review/sparring: after reading `/tmp/<name>-turn.txt`, remove it; remove `/tmp/<name>-native.log` or `/tmp/<name>-sparring.log` when the dialogue will not continue.

If the user asks for an ongoing tmux sparring session, leave it running and report the attach command.

If the user asks for a quick tmux test, cleanup after the test:

```bash
$SPARRING_HARNESS stop <name>
```

## Reporting Back

Report briefly:

- Use a structured, human-readable synthesis rather than a transcript dump.
- Include a short final recommendation first.
- Include the understood task, high-level framing checks, disputed points, agreements, changed decisions, compared alternatives, remaining trade-offs, and next steps.
- Use tables, short lists, and comparisons when they make the result easier to scan.
- If missing user data stopped the sparring, return a question table with: question, why it is needed, and what decision it affects.
- Mention which opponent backend and mode were used (`ask-session`, `ask-resume`, or tmux), but keep mechanics secondary to the decision.
- Mention state/session file paths only if they remain useful for continued sparring.
- Preserve the user's language in the final answer unless they explicitly ask otherwise.

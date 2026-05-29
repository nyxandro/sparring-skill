<div align="center">

# Sparring

**Make rival CLI agents spar.**
Ask Claude, Codex or another agent for an independent answer, feed it back into your own
reasoning, and continue the debate with a retained local history.

[![Shell](https://img.shields.io/badge/shell-bash%204%2B-4EAA25?logo=gnubash&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20WSL%20%7C%20macOS-555)](#requirements)
[![Mode](https://img.shields.io/badge/mode-print--first-blue)](#two-modes)
[![tmux](https://img.shields.io/badge/tmux-3.x%20(fallback)-1BB91F?logo=tmux&logoColor=white)](#two-modes)
[![License](https://img.shields.io/badge/license-MIT-black)](#license)

</div>

---

## What it does

`sparring` runs two rival agents against the same task, then makes them **spar**: each agent is
fed the other's answer and asked to critique it. You keep a local dialogue history across turns
and incorporate the opponent's reasoning into your own.

The production path is **print-first**: `claude -p` and `codex exec` are driven over plain stdin
and their stdout is captured deterministically. A tmux harness remains as a *live-watch* mode and
as a fallback for agents that only expose an interactive TUI.

## Requirements

- Linux / WSL or macOS with a GNU-compatible userland.
- **Bash 4+** — `bin/spar` uses associative arrays (not macOS bash 3.2 compatible).
- GNU `timeout` (coreutils) for print/exec calls.
- `tmux 3.x` — **only** for live/fallback mode; print-first needs no tmux.
- The target agent CLI on `PATH` (`claude`, `codex`, …).
- Trusted local shell. Agent commands are run as shell commands, not sandboxed input.

## Quick start

```bash
# Deterministic demo with built-in mock agents (no API cost):
bin/spar
bin/spar "Design a caching layer for the search endpoint."

# One-shot answer from a real agent:
bin/sparctl ask-print claude "Reply briefly: ping"   /tmp/claude.txt
bin/sparctl ask-print codex  "Critique this plan"     /tmp/codex.txt

# Stateful dialogue — the session file is replayed as context each turn:
bin/sparctl ask-session claude /tmp/session.log "Open the debate"     /tmp/turn-1.txt
bin/sparctl ask-session claude /tmp/session.log "Answer the critique" /tmp/turn-2.txt

# Verify the harness:
bash test/run-all.sh
```

## Two modes

| | Print-first (default) | tmux (fallback / live) |
|---|---|---|
| **Transport** | stdin → CLI → stdout | `send-keys` / `capture-pane` |
| **Completion** | provider exit code | screen-stabilisation polling |
| **Reliability** | high (clean stream) | heuristic (scrapes a rendered TUI) |
| **Use when** | normal sparring | agent has no print mode, or you want to watch live |

### Provider mapping (print mode)

| Agent | Command |
|---|---|
| `claude` | `claude -p --permission-mode plan --output-format text` |
| `codex`  | `codex exec --sandbox read-only --skip-git-repo-check --color never -C <cwd> --output-last-message <file> -` |

Prompts go through **stdin**, not argv — long histories avoid `ARG_MAX` and never appear in
process listings. A provider that exits cleanly with an empty answer fails fast with
`SPAR_PRINT_EMPTY_ANSWER`.

## `sparctl` commands

Print-first:

| Command | Purpose |
|---|---|
| `ask-print <name> <text> <out>` | One-shot non-interactive answer. |
| `ask-session <name> <session> <text> <out>` | Stateful answer; replays bounded history. |
| `ask-auto <name> <text> <out>` | Try print, fall back to tmux automatically. |

tmux (live / fallback):

| Command | Purpose |
|---|---|
| `start [--replace] [name] [cmd]` | Create a persistent session (fails if it exists). |
| `send <name> <text>` | Type a prompt without waiting. |
| `ask <name> <text>` | Send, wait for idle, print the cleaned delta. |
| `ask-delta <name> <text> <out>` | Save only the new transcript rows. |
| `ask-watch <name> <text> <out>` | Spool transcript changes while the agent works. |
| `ask-once <name> <cmd> <text> <out>` | Fresh session with the prompt as an initial arg. |
| `wait` / `screen` / `transcript [out]` | Block until idle / print pane / dump scrollback. |
| `attach` / `sessions` / `stop <name>` | Attach, list, or kill sessions. |

```bash
# Persistent live session you can attach to:
bin/sparctl start claude
tmux attach -t spar-claude
bin/sparctl ask-delta claude "Give a detailed plan" /tmp/claude-delta.txt
bin/sparctl stop claude
```

## Configuration

Print mode — `lib/print-agent.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `SPAR_PRINT_TIMEOUT` | `300` | Hard cap (s) per provider call. |
| `SPAR_PRINT_CONTEXT_LINES` | `400` | History lines replayed each stateful turn. |

tmux idle detection — `lib/tmux-agent.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `POLL_INTERVAL` | `0.4` | Seconds between screen samples. |
| `WAIT_MIN_POLLS` | `8` | Min samples before idle accepted (slow-first-token margin). |
| `STABLE_SAMPLES` | `4` | Consecutive unchanged samples that mean "done". |
| `GRACE_SAMPLES` | `2` | Initial samples ignored (screen static before work). |
| `WAIT_TIMEOUT` | `90` | Give up after this many seconds. |
| `TMUX_HISTORY_LIMIT` | `200000` | Retained scrollback rows for persistent sessions. |

```bash
# Point the demo at a real agent instead of the mock:
SPAR_AGENT_CMD="claude" bin/spar "Draft a 3-step rollout plan for feature flags."
```

## Layout

```
sparring/
├─ bin/
│  ├─ spar            # dispatcher demo (entrypoint)
│  ├─ sparctl         # print-first CLI + tmux live/fallback controls
│  └─ mock-agent.sh   # fake interactive agent for cost-free testing
├─ lib/
│  ├─ print-agent.sh  # claude -p / codex exec providers + session history
│  └─ tmux-agent.sh   # spawn / send / wait-idle / collect over tmux
└─ test/
   ├─ smoke.sh        # spawn → send → wait_idle → collect
   ├─ print.sh        # print providers, session history, tmux fallback
   ├─ sparctl.sh      # persistent lifecycle on an isolated tmux socket
   └─ run-all.sh      # full suite
```

## Known limits (tmux mode only)

Inherent to scraping a rendered terminal rather than a clean stdout stream:

- **Single-line input.** Multi-line content is flattened before sending.
- **Heuristic echo cleanup.** Wrapped-echo re-joining can mis-trim in rare cases.
- **Timing-based idle.** A long mid-answer pause can read as "done" early — tune the constants.
- **Trusted command strings.** Configured agent commands run in a shell; never pass untrusted text.

Print mode avoids all of the above — prefer it whenever the agent supports a non-interactive mode.

## License

MIT

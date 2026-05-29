# Sparring Skill

![Sparring Skill](./sparring.png)

[![Download Skill](https://img.shields.io/badge/Download-sparring.skill-blue?style=for-the-badge)](https://github.com/nyxandro/sparring-skill/raw/main/dist/sparring.skill)

Sparring Skill is for the moments when one model's answer is not enough.

Ask your main agent to “do sparring with Claude” or “do sparring with Codex”, and it will ask the
other CLI agent for an independent opinion, read the answer, and fold that second point of view
back into the final response.

Use it for:

- brainstorming an idea before implementing it;
- getting a second opinion on architecture or a plan;
- reviewing code or a risky change;
- comparing alternatives;
- stress-testing your own conclusion.

The normal workflow is intentionally simple:

```text
Do sparring with Claude on this plan.
Run a sparring review with Codex.
Get a second opinion through sparring.
Discuss this architecture with Claude.
```

The skill handles the mechanics: chooses the right CLI command, writes temporary answer files,
reads them back, cleans them up, and summarizes what changed after the sparring.

## How It Works

The production path is non-interactive CLI mode:

- Claude is called through `claude -p`.
- Codex is called through `codex exec`.
- Multi-turn sparring keeps a small local session history and sends it as context on the next turn.
- Native-resume sparring can instead continue the provider's own saved session with `claude --resume`
  or `codex exec resume`, while keeping a local audit transcript.
- Temporary output files are deleted after they are read unless you explicitly ask to keep them.

There is also a tmux mode for live interactive agents. Use it only when non-interactive CLI mode is not
available or when you specifically want to watch the other agent in a terminal session.

## Install

The committed `dist/sparring.skill` file is the downloadable skill archive. It contains the same
self-contained skill folder as `sparring/`: `SKILL.md` plus the runtime harness under `bin/` and
`lib/`; no external checkout or build step is required after download.

Install the current skill file into OpenCode:

```bash
rm -rf ~/.config/opencode/skills/sparring
unzip dist/sparring.skill -d ~/.config/opencode/skills
```

Install it into Claude Code:

```bash
rm -rf ~/.claude/skills/sparring
unzip dist/sparring.skill -d ~/.claude/skills
```

For local development, copying the `sparring/` folder directly into the skills directory is also
valid. Restart OpenCode or Claude Code after updating the skill.

## Requirements

- Linux with Bash 4+.
- GNU `timeout` for non-interactive CLI mode.
- `claude` and/or `codex` installed and authenticated.
- `tmux` only for fallback/live mode.

## Known Limits

- Non-interactive CLI mode is the reliable production path; tmux mode is for interactive TUIs.
- Tmux input is submitted as one line. Multi-line prompts are flattened before sending so they do
  not become multiple accidental turns.
- Tmux completion is detected by screen stability, not by a provider event. Very long pauses inside
  a TUI response can still be ambiguous; use transcript export for long answers.

## Developer Commands

Most users do not need these directly; the skill calls them for you.

```bash
# Sparring with local history.
sparring/bin/sparctl ask-session claude /tmp/sparring.log "First question" /tmp/turn-1.txt
sparring/bin/sparctl ask-session claude /tmp/sparring.log "Follow-up" /tmp/turn-2.txt

# Multi-turn sparring with provider-native resume.
sparring/bin/sparctl ask-resume claude /tmp/claude-native.log "First question" /tmp/turn-1.txt
sparring/bin/sparctl ask-resume claude /tmp/claude-native.log "Follow-up" /tmp/turn-2.txt
sparring/bin/sparctl ask-resume codex /tmp/codex-native.log "First question" /tmp/codex-turn.txt
sparring/bin/sparctl ask-resume codex /tmp/codex-native.log "Follow-up" /tmp/codex-turn.txt

# Live tmux session, only when you want to watch or when non-interactive CLI mode is unavailable.
sparring/bin/sparctl start claude
tmux attach -t spar-claude
sparring/bin/sparctl stop claude
```

Run the full regression suite:

```bash
bash test/run-all.sh
```

## Project Layout

```text
sparring/SKILL.md           skill instructions
sparring/bin/sparctl        non-interactive CLI plus tmux controls
sparring/lib/print-agent.sh claude -p / codex exec providers and session history
sparring/lib/tmux-agent.sh  live tmux fallback primitives
dist/sparring.skill         downloadable self-contained skill archive
test/                       smoke and regression tests
```

## Notes

Non-interactive CLI mode is preferred because it captures clean stdout and avoids terminal scraping.
Tmux mode is kept for agents that only expose an interactive TUI, but it is inherently more heuristic.

## License

MIT

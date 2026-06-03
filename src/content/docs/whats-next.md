---
title: What's next
description: Three next versions of agent-tts — streaming, voice cloning, and native Claude Code voice via MCP.
---

## TL;DR

v1.1 shipped multilingual code-switch (`MultiPiperEngine` + `--lang auto|pt|en` + En Amy voice routing). v1.3 shipped Linux espeak-ng + systemd + CI matrix. **What follows is about reach, not plumbing.** Three themes pulled out of the v1.1+v1.3 backlog and pointed at the audiences that will care.

Vote, watch, or send a PR at [biliboss/agent-tts](https://github.com/biliboss/agent-tts).

---

## v1.2 — Streaming · *First word before the last is written*

> Sub-100 ms warm synth is great for short messages. For a 500-word agent monologue, the user still waits ~3 s for the first sample. v1.2 fixes that.

**The problem today.** Pre-processing + synth happen serially on the whole input. Long deploys, long reviews, long agent decisions all start late.

**What ships.** Sentence-boundary chunking in `preproc.zig`. The worker dispatches chunk 1 to the engine while the preprocessor is still chewing chunk N. The audio queue stitches the PCM streams back-to-back via zaudio.

**Why now.** zaudio already exposes the callback-driven path. The remaining work is preprocessor state, an internal chunk queue, and gapless playback hinting.

**Who cares.**
- Anyone who runs `agent-tts "$(cat huge-output.txt)"`.
- Agents that summarize commits, PRs, or `git diff` outputs.
- Accessibility users on dynamic feeds (notifications, transcripts).

---

## v1.4 — Voice cloning · *Your voice, your agent*

> Faber is a great default. But the agent that ships your code should sound like you.

**The problem today.** Every agent that uses `agent-tts` sounds identical. There is no personalization knob beyond `--voice "Felipe (Premium)"` for `say`.

**What ships.** A `voice clone` subcommand. Drop a 30-second WAV in, get a custom ONNX checkpoint out. Drops into the same `voices/` directory as Faber and works with `--voice <slug>`.

```bash
agent-tts voice clone --sample me-reading.wav --name gabriel
agent-tts --voice gabriel "Deploy concluído."
```

**Why now.** XTTS-v2 cloning works locally on Apple Silicon today. Wrapping it as a one-shot command is mostly UX.

**Who cares.**
- Solo devs branding their agent.
- Studios where the AI narrator should match a human voiceover.
- Accessibility users who want a familiar voice on their own machine.

---

## v1.5 — MCP server · *Native Claude Code voice*

> Today, Claude Code shells out to `agent-tts` via Bash. That works, but it's not native. v1.5 makes the agent speak through the same protocol it reads.

**The problem today.** Shelling out costs a tool call slot, a roundtrip, and a permission prompt. There is no streaming, no SKIP from the agent's side, no queue inspection without parsing stdout.

**What ships.** An [MCP](https://modelcontextprotocol.io) server bundled in the same Zig binary. New subcommand:

```bash
agent-tts mcp                # speak over stdio MCP, no shell
```

Tools exposed:

| Tool | What it does |
|------|--------------|
| `say(text, engine?, voice?, rate?)` | enqueue + return item id |
| `queue()` | list current items |
| `skip(id?)` | skip current or specific |
| `clear()` | drop pending |
| `voices()` | list installed voices |

**Why now.** MCP is the protocol every agent runner is converging on (Claude Code, Cursor, Cline, Continue). agent-tts already has a stable line protocol — MCP is a thin shim over it.

**Who cares.**
- Every Claude Code user. (Native voice, no shell prompt.)
- Cursor / Cline / Continue users — same MCP works everywhere.
- Anyone building an agent platform that wants TTS without writing their own.

---

## How to influence the order

The roadmap is not locked. The next milestone is the one with the loudest signal.

- 👍 [GitHub issues with the `roadmap` label](https://github.com/biliboss/agent-tts/labels/roadmap)
- ⭐ Star the repo — repo traffic guides priority
- 🛠 Send a PR — the changelog will name you

See also: [Roadmap](/roadmap/), [Changelog](/changelog/), [TTS engine](/motor/).

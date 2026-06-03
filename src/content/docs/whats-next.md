---
title: What's next
description: Four next versions of agent-tts (v1.6 → v1.10, minus v1.9 which shipped) — voice cloning ship-it, streaming text input, SSML/prosody, and menubar UI.
---

## TL;DR

The whole **v1.1 → v1.5** marketing slate shipped on **2026-06-03**, plus **v1.9** (Web playground scaffold) the same day. The remaining slate (**v1.6 → v1.10**, minus v1.9) takes the runtime and points it at four distinct audiences: people who want their cloned voice to actually work, people who want the agent to start speaking before it finishes thinking, people who want their agent to inflect, and people who want a face on the daemon. The v1.9.1 follow-up (WASM Piper synth wired into the playground) is tracked separately.

Vote, watch, or send a PR at [biliboss/agent-tts](https://github.com/biliboss/agent-tts).

---

## v1.6 — Voice cloning ship-it · *Your voice, for real*

> v1.4 shipped the **scaffold** for voice cloning. The Python sidecar is wired, the subcommand validates, the daemon dispatches — but `scripts/setup-voice-clone.sh` has never been run end-to-end and the first cloned voice was never measured. v1.6 closes that gap.

**The problem today.** `agent-tts voice clone --sample me.wav --name gabriel` writes `metadata.json` and walks off whistling. The Python side (XTTS-v2, ~1.8 GB model) was deferred to v1.4.1.

**What ships.**
- `scripts/setup-voice-clone.sh` validated on a clean macOS install (Apple Silicon + Intel via Rosetta) and a fresh Ubuntu 22.04
- Real Gabriel-voice + Mauricio-voice published in `_qa/v1.6-baseline.md` with cold sidecar startup, warm first-sample latency, and quality A/B vs Faber
- `voice list` shows quality + duration + sample-rate alongside the slug
- Per-voice fallback chain documented (cloned → piper Faber → say Luciana) — actually exercised under failure injection

**Why now.** v1.5 closed the protocol layer (MCP), v1.6 closes the personalisation layer. Personal voice on a permission-prompt-free MCP server is the killer demo for the agent-builder audience.

**Who cares.**
- Solo devs branding their agent.
- Studios where the AI narrator matches a human voiceover.
- Accessibility users on a familiar voice they own.

---

## v1.7 — Streaming text input · *Listen as your agent thinks*

> Today, `agent-tts "long output"` waits for the full input before sentence-chunking. For a Claude Code reply being streamed token-by-token, that delay defeats the streaming UX of the LLM itself.

**The problem today.** `agent-tts` is a one-shot enqueue. Each message is a complete utterance.

**What ships.**
- New `agent-tts stream` subcommand that reads from stdin and emits sentences to the daemon as the terminator tokens (`. ! ? \n`) arrive
- New MCP tool `say_stream(stream_id, chunk, final?)` so MCP clients can push deltas the same way the OpenAI / Anthropic SDKs push response deltas
- Daemon reuses the v1.2 streaming pipeline — synth/audio thread already exist, just hook them to an incrementally-fed chunk source
- Bench captures *latency from first token-in to first audio-out* against a simulated stream — that is the headline number

**Why now.** Token streaming is how every agent runner ships responses. agent-tts should match the input shape of the LLM, not run a beat behind it.

**Who cares.**
- Anyone wiring `claude --output-format stream-json` into a voice channel.
- Voice-assistant builders (think Bestha, Ferrum) where reply latency owns the experience.
- Accessibility users on long documents — start hearing while the agent is still composing.

---

## v1.8 — SSML & prosody · *Your agent finally inflects*

> Faber speaks Pt-BR cleanly, but flat. `Say` accepts `[[slnc]]` / `[[rate]]` / `[[pbas]]` cues. Piper accepts none. The agent's voice has no shape.

**The problem today.** No emphasis. No emotion. No deliberate pauses on punchlines. Every sentence has the same energy curve.

**What ships.**
- W3C [SSML 1.1](https://www.w3.org/TR/speech-synthesis11/) subset support: `<emphasis>`, `<break>`, `<prosody rate pitch volume>`, `<say-as interpret-as="...">`
- For Piper Faber: the preprocessor mutates phoneme sequences before synth (slow zone vs fast zone via length-scale tweaks in the ONNX session)
- For `say`: SSML transpiles to the native `[[...]]` directives, no behaviour change for users
- New MCP tool argument `ssml: true` so agents can send marked-up text directly
- Bench measures: *time from `<emphasis>` markup to audible prosody change* on warm Faber

**Why now.** Long-form agents (interviews, narrations, demos) need pacing to land. Pt-BR especially — flat delivery sinks the listener's attention faster than in English.

**Who cares.**
- Studios producing AI narration / podcasts.
- Educational tools where pacing affects comprehension.
- Anyone building a voice agent that should sound less robotic than the *current* state-of-the-art.

---

## v1.10 — Menubar UI · *Voice agent gets a face*

> The daemon runs invisible. Skip/clear/queue are CLI verbs. v1.10 ships a 200×400 menubar app showing the queue, the currently-playing item, and a one-click voice picker.

**The problem today.** `agent-tts queue` is the only window into the daemon. There is no skip button, no volume slider, no visual cue that the agent just started speaking.

**What ships.**
- macOS menubar app (Swift, SwiftUI, ~1 MB binary) talking the same UNIX socket protocol as the CLI
- Live queue with `pending` / `playing` highlight, click-to-skip, drag-to-reorder
- Voice picker dropdown (Faber / Amy / Luciana / cloned) — switches the daemon's default mid-session
- "Volume duck while speaking" toggle — drops other apps' output to 30% during agent speech via CoreAudio AVAudioSession ducking
- Linux equivalent ships as a GTK4 status icon (best-effort, less polish)
- The daemon stays unchanged — UI is a thin LiveView-style client, all state lives on the socket

**Why now.** Once an agent speaks well, the next question is "how do I see what it's doing?" v1.10 makes the daemon legible. Also, "menubar app" is the proof-point that puts agent-tts on Product Hunt and into "AI tools for Mac" lists.

**Who cares.**
- Power users who like agent voice but want visible controls.
- Mac users who expect every background daemon to have a menubar entry.
- Onlookers — the menubar icon is the only ad agent-tts will ever buy.

---

## How to influence the order

The next milestone is the one with the loudest signal.

- 👍 [GitHub issues with the `roadmap` label](https://github.com/biliboss/agent-tts/labels/roadmap)
- ⭐ Star the repo — repo traffic guides priority
- 🛠 Send a PR — the changelog will name you

See also: [Roadmap](/roadmap/), [Changelog](/changelog/), [TTS engine](/motor/), [MCP server](/mcp/).

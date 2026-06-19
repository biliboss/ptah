---
title: MCP server
description: Native Claude Code / Cursor / Cline voice — ptah speaks via stdio JSON-RPC since v1.5, 13 tools as of v1.10.13.
---

## TL;DR

`ptah mcp` runs a stdio JSON-RPC 2.0 server that exposes the daemon to any [Model Context Protocol](https://modelcontextprotocol.io) client. Claude Code, Cursor, Cline, Continue — same wire, same **13 tools** as of v1.10.13. Curated knob+post-fx discovery (`tech_profile_search`) landed in v1.10.9 / v1.10.10, on top of the v1.10.7 / v1.10.8 per-call Kokoro knobs and the v1.10.2 player ops. No shell-out, no permission prompt per call, no stdout parsing.

Bundled in the same Zig binary as the CLI and the daemon. `+115 KB` over v1.0. Tools only — `prompts/`, `resources/`, `sampling/` are deferred and remain so through v1.10.13.

## Install snippet

Canonical Claude Code config — paste into `~/.claude.json` (or your MCP client's equivalent):

```json
{
  "mcpServers": {
    "ptah": {
      "command": "/opt/homebrew/bin/ptah",
      "args": ["mcp"]
    }
  }
}
```

One-shot via the Claude Code CLI (project-scoped — checks the config into `.mcp.json` in the repo):

```bash
claude mcp add ptah /opt/homebrew/bin/ptah mcp --scope project
```

Or use the bundled installer that merges into `~/.claude.json` idempotently with a backup:

```bash
./scripts/install-mcp.sh
```

The installer refuses to touch a JSON file that does not parse as an object. Restart Claude Code (or your client) so it picks up the new server. Verify:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ptah mcp
```

You should get back a single JSON line listing the 13 tools.

## The 13 tools

| Tool | Description | Args | Returns |
|------|-------------|------|---------|
| `say` | enqueue Pt-BR TTS + return queue id | `text`, `engine?`, `voice?`, `rate?`, `ssml?`, `length_scale?`, `noise_scale?`, `noise_w?`, `tech?`, `comma_pause_ms?`, `sentence_pause_ms?`, `newline_pause_ms?`, `speaker_id?`, `postfx?` | `{ id }` |
| `queue` | list pending + playing items | none | `{ items: [...] }` |
| `skip` | skip the currently playing item | `{ id? }` (currently ignored — always skips the head) | `{ skipped_id }` (0 = nothing was playing) |
| `clear` | drop all pending items | none | `{ cleared_count }` |
| `voices` | list installed voices for `say` + Kokoro voice packs in `~/.cache/ptah/voices/` | none | `{ voices: [...] }` |
| `say_stream` (v1.7+) | streaming chunk-by-chunk enqueue; sentences flush as terminators arrive | `stream_id`, `chunk`, `final?`, `engine?`, `voice?`, `rate?` | `{ enqueued_count, final }` |
| `pause` (v1.10.2+) | pause the active piper / cloned playback | none | `{ paused_id }` (0 = nothing playing) |
| `resume` (v1.10.2+) | resume a paused item | none | `{ resumed_id }` (0 = not paused) |
| `replay` (v1.10.2+) | re-enqueue a past item by id (any state) | `{ id }` | `{ new_id }` (0 = item not found) |
| `history` (v1.10.2+) | list the last N items (incl. done / skipped) | `{ limit? }` (1..100, default 20) | `{ items: [{id,state,engine,voice,rate,finished_at,text}, ...] }` |
| `synth_voice_test` (v1.10.7+) | one-shot Kokoro Dora A/B with explicit knobs (always routes to Dora so knob effect is comparable) | `text`, `length_scale?`, `noise_scale?`, `noise_w?`, `tech?`, `comma_pause_ms?`, `sentence_pause_ms?`, `newline_pause_ms?`, `speaker_id?`, `postfx?` | `{ id, length_scale, noise_scale, noise_w, tech, ..., postfx }` |
| `voice_knob_search` (v1.10.8+) | N-variant knob hyperplane in one MCP round-trip (cap 16) | `text`, `variants: [{...knobs, comment?}]`, `max_variants?` | `{ items: [{id, comment, knobs}], truncated }` |
| `tech_profile_search` (v1.10.9 / v1.10.10) | curated 4×2 tech-narration matrix in one call | `{ text }` | `{ items: [{id, name, postfx, comment, knobs}], count: 8 }` |

Each tool is a thin shim over the same UNIX socket the CLI uses. Tool-level errors (daemon down, malformed args) come back as `isError: true` MCP responses with a human-readable text block — the JSON-RPC envelope only errors on parse failures (`-32700`) or unknown methods (`-32601`).

### v1.10.9 / v1.10.10 — `tech_profile_search` 4×2 matrix

`tech_profile_search` enqueues a curated **4 knob bundles × 2 postfx modes = 8 items** in a single MCP round-trip. Each variant routes to Kokoro Dora with `tech=true` (acronym / unit / brand-phonetics glossary on). The fixed bundles ship in `src/mcp.zig::callTechProfileSearch`:

| Profile | `length_scale` | `noise_scale` | `noise_w` | Intent |
|---|---|---|---|---|
| `tight-narrator` | 1.05 | 0.35 | 0.45 | v1.10.9 research-anchored default — recovers intelligibility on symbol-heavy strings without flattening prosody |
| `stock-tech` | 0.95 | 0.667 | 0.85 | v1.10.8 default — Dora's stock recommendation, warmer + faster |
| `broadcast` | 1.00 | 0.50 | 0.60 | balanced read for narrated release notes |
| `expressive` | 1.10 | 0.80 | 1.00 | wider prosody range — better for marketing copy, worse for acronyms |

Each profile is enqueued **twice** — once dry (`postfx=off`) and once with the v1.10.10 research-anchored chain (`postfx=tech` = RNNoise + 4-band EQ + de-esser + 2:1 compressor). The returned `comment` is `"<profile> + postfx=<mode>"` so a caller can A/B both knob AND post-fx in one round-trip. See [motor → Audio post-processing](/ptah/motor/#audio-post-processing-v11010) for the exact ffmpeg filter graphs and the RNNoise model install.

### v1.10.10 — `postfx` on `say` and `synth_voice_test`

Both tools accept an optional `postfx` enum routing the synth PCM through an ffmpeg subprocess before afplay plays it. Values: `off` (default — dry path) / `clean` (highpass + light comp) / `tech` (RNNoise + EQ + de-esser + 2:1 comp) / `broadcast` (EQ + de-esser + 3:1 comp). ffmpeg must be on `PATH` (or at `$PTAH_FFMPEG_PATH`); when missing the chain falls back to dry PCM silently. RNNoise also needs a model at `$PTAH_POSTFX_RNNN_MODEL` or `~/.cache/ptah/rnnoise/cb.rnnn`.

> v1.10.13 fixed a postfx two-pipe deadlock — the stdin write and stdout drain now run concurrently with a 5-second watchdog (`PTAH_POSTFX_TIMEOUT_MS`). Postfx calls are safe to drive at queue depth ≥10 again.

### v1.10.7 — Per-call Kokoro knobs on `say`

The `say` tool gains three optional numeric parameters that override Kokoro inference per call. Each is honored only when the daemon routes to `engine=kokoro` (the default):

| Parameter | Range | Effect |
|---|---|---|
| `length_scale` | 0.1 – 3.0 | <1 = faster; >1 = slower. Overrides `<prosody rate>` only outside SSML markup. |
| `noise_scale` | 0 – 2 | Higher = more prosody variation. Dora stock ≈0.667; tight-narrator anchor ≈0.35. |
| `noise_w` | 0 – 2 | Higher = more pronunciation variation. Dora stock ≈0.85; tight-narrator anchor ≈0.45. |

Use `synth_voice_test` as the targeted A/B helper — it always routes to Kokoro Dora and echoes the resolved knobs in the response so an agent can record the experiment. Use `tech_profile_search` when you want the production-ready 4×2 curated matrix in one call.

### v1.10.8 — Tech mode + max knobs

Five more optional params land on `say` + `synth_voice_test`:

| Parameter | Range | Effect |
|---|---|---|
| `tech` | boolean | Run the tech-report glossary (acronyms spelled, units expanded, brand phonetics, CamelCase splitter, path/version/commit-hash normalizer — v1.10.9 grew the dictionary). |
| `comma_pause_ms` | 0 – 5000 | Override `[[slnc N]]` after `,` (default 150). 0 = use default. |
| `sentence_pause_ms` | 0 – 5000 | Override `[[slnc N]]` after .!? (default 400). Tech profile uses 500. |
| `newline_pause_ms` | 0 – 5000 | Override `[[slnc N]]` after newline (default 600). |
| `speaker_id` | -1 – 1000 | Piper multi-speaker integer. -1 = voice default. Dora is single-speaker. |

The **`voice_knob_search`** tool lets an agent scan an N-variant knob hyperplane in **one MCP round-trip** instead of N sequential `tools/call`s. Each variant carries any subset of the per-call knobs plus a free-form `comment`. Cap: 16 variants.

Sample:

```json
→ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{
    "name":"voice_knob_search",
    "arguments":{
      "text":"API rodou em 250 ms.",
      "variants":[
        {"length_scale":0.95,"noise_scale":0.667,"noise_w":0.85,"tech":true,"comment":"warm-tech"},
        {"length_scale":1.05,"noise_scale":0.35,"noise_w":0.45,"tech":true,"comment":"tight-narrator"},
        {"length_scale":0.85,"noise_scale":0.5,"noise_w":0.7,"tech":true,"sentence_pause_ms":600,"comment":"fast-paused"}
      ]
    }
  }}
← {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"145\",\"comment\":\"warm-tech\",\"knobs\":{...}}, ...],\"truncated\":false}"}],"isError":false}}
```

## JSON-RPC samples

`initialize` — first call from the client, response carries server capabilities:

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"ptah","version":"1.10.13"}}}
```

`tools/list` — enumerate the 13 tools (order: `say`, `queue`, `skip`, `clear`, `voices`, `say_stream`, `pause`, `resume`, `replay`, `history`, `synth_voice_test`, `voice_knob_search`, `tech_profile_search`):

```json
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"say","description":"Enqueue Pt-BR TTS on the running daemon. ...","inputSchema":{"type":"object","properties":{"text":{"type":"string"}, "engine":{"type":"string","enum":["say","piper"]}, "voice":{"type":"string"}, "rate":{"type":"integer"}, "postfx":{"type":"string","enum":["off","clean","tech","broadcast"]}, ...}, "required":["text"]}}, ...]}}
```

`tools/call → say` with v1.10.10 postfx:

```json
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"say","arguments":{"text":"Deploy concluído","engine":"piper","tech":true,"postfx":"tech"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"id\":\"42\"}"}],"isError":false}}
```

`tools/call → tech_profile_search`:

```json
→ {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"tech_profile_search","arguments":{"text":"Release v1.10.13 — RNNoise + EQ + de-esser estável a 60 fps. API rodou em 250 ms."}}}
← {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"200\",\"name\":\"tight-narrator\",\"postfx\":\"off\",\"knobs\":{...}}, ...],\"count\":8}"}],"isError":false}}
```

`tools/call → queue`:

```json
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"queue","arguments":{}}}
← {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"42\",\"state\":\"playing\",\"engine\":\"piper\",\"voice\":\"pf_dora\",\"rate\":\"330\",\"text\":\"Deploy concluído\"}]}"}],"isError":false}}
```

`tools/call → voices`:

```json
→ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"voices","arguments":{}}}
← {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"{\"voices\":[{\"engine\":\"say\",\"name\":\"Dora\",...},{\"engine\":\"piper\",\"name\":\"pf_dora\",...}]}"}],"isError":false}}
```

Tool error path — daemon not running:

```json
→ {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"queue","arguments":{}}}
← {"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"daemon not running"}],"isError":true}}
```

## Claude Code walkthrough

1. Build + install ptah:
   ```bash
   zig build -Doptimize=ReleaseFast
   cp zig-out/bin/ptah /opt/homebrew/bin/
   ptah daemon install   # autostart at login
   ```
2. Register the MCP server (paste the snippet above into `~/.claude.json`, or run `./scripts/install-mcp.sh`, or `claude mcp add ptah /opt/homebrew/bin/ptah mcp --scope project`).
3. Restart Claude Code. All 13 tools show up under the `ptah` server.
4. Ask Claude to use one: *"Use tech_profile_search to read this release-note paragraph in Portuguese — I want to pick the best knob+post-fx combo."* The agent will enqueue the 4×2 matrix and report back the 8 ids.

The daemon does the actual synthesis — the MCP server is a stateless bridge. Killing the MCP process between calls is fine; Claude Code spawns one per session.

## Honest deferrals

| Capability | Status | Why |
|------------|--------|-----|
| `prompts/*` | not implemented | voice agents do not need prompt templates |
| `resources/*` | not implemented | the daemon owns no addressable content |
| `sampling/*` | not implemented | nothing in ptah asks the LLM to think |
| `logging/*` | not implemented | daemon logs land in `~/.cache/ptah/daemon.log` (v1.10.13 rotating sink) already |
| `notifications/tools/list_changed` | declared off (`listChanged: false`) | tool list never changes mid-session |
| `skip(id)` | argument accepted, ignored | the daemon's SKIP only targets the head; per-id skip pending |
| `voices` enumerating all installed `say` voices | hardcoded macOS system voices | `say -v ?` would cost a process per call |
| End-to-end test against a real Claude Code | partial | scaffolded via `echo | ptah mcp` smoke tests; full client validation done for `say`/`queue`/`history`/`pause` in v1.10.2 live session |

## Related

- [Architecture](/ptah/arquitetura/) — MCP server slots into "Components"
- [Motor](/ptah/motor/) — `postfx=tech` filter graph + RNNoise model wiring
- [Changelog](/ptah/changelog/) — v1.10.9 (`tech_profile_search`) and v1.10.10 (`postfx` + 4×2 matrix) entries
- [MCP spec](https://modelcontextprotocol.io/specification/2024-11-05) — the protocol ptah speaks

---
title: MCP server
description: Native Claude Code / Cursor / Cline voice — agent-tts speaks via stdio JSON-RPC since v1.5.
---

## TL;DR

`agent-tts mcp` runs a stdio JSON-RPC 2.0 server that exposes the daemon to any [Model Context Protocol](https://modelcontextprotocol.io) client. Claude Code, Cursor, Cline, Continue — same wire, same **10 tools** (v1.10.2). No shell-out, no permission prompt per call, no stdout parsing.

Bundled in the same Zig binary as the CLI and the daemon. `+115 KB` over v1.0. Tools only — `prompts/`, `resources/`, `sampling/` are deferred.

## Install

Recommended path — let the installer merge into `~/.claude.json`:

```bash
./scripts/install-mcp.sh
```

The installer is idempotent, backs up `~/.claude.json` before writing, and refuses to touch a JSON file that does not parse as an object.

Manual path — paste this block into `~/.claude.json` (or your MCP client's equivalent):

```json
{
  "mcpServers": {
    "agent-tts": {
      "command": "/opt/homebrew/bin/agent-tts",
      "args": ["mcp"]
    }
  }
}
```

Then restart Claude Code (or your client) so it picks up the new server. Verify:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | agent-tts mcp
```

You should get back a single JSON line listing the 10 tools.

## The 10 tools

| Tool | Args | Returns |
|------|------|---------|
| `say` | `{ text, engine?, voice?, rate?, ssml? }` | `{ id }` |
| `queue` | `{}` | `{ items: [...] }` |
| `skip` | `{ id? }` (ignored in v1.5) | `{ skipped_id }` |
| `clear` | `{}` | `{ cleared_count }` |
| `voices` | `{}` | `{ voices: [...] }` |
| `say_stream` (v1.7+) | `{ stream_id, chunk, final?, engine?, voice?, rate? }` | `{ enqueued_count, final }` |
| `pause` (v1.10.2+) | `{}` | `{ paused_id }` (0 = nothing playing) |
| `resume` (v1.10.2+) | `{}` | `{ resumed_id }` (0 = not paused) |
| `replay` (v1.10.2+) | `{ id }` | `{ new_id }` (0 = item not found) |
| `history` (v1.10.2+) | `{ limit? }` (1..100, default 20) | `{ items: [{id,state,engine,voice,rate,finished_at,text}, ...] }` |

Each tool is a thin shim over the same UNIX socket the CLI uses. No new daemon code beyond the v1.10.2 ops the four new tools wrap. Tool errors (daemon down, malformed args) come back as `isError: true` MCP responses with a human-readable text block — the JSON-RPC envelope only errors on parse failures (`-32700`) or unknown methods (`-32601`).

## JSON-RPC samples

`initialize` — first call from the client, response carries server capabilities:

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"agent-tts","version":"1.5.0"}}}
```

`tools/list` — enumerate the 5 tools:

```json
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"say","description":"Enqueue Pt-BR TTS on the running daemon. Returns the queue item id.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}, "engine":{"type":"string","enum":["say","piper"]}, "voice":{"type":"string"}, "rate":{"type":"integer"}}, "required":["text"]}}, ...]}}
```

`tools/call → say`:

```json
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"say","arguments":{"text":"Deploy concluído","engine":"piper"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"id\":\"42\"}"}],"isError":false}}
```

`tools/call → queue`:

```json
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"queue","arguments":{}}}
← {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"42\",\"state\":\"playing\",\"engine\":\"piper\",\"voice\":\"faber\",\"rate\":\"330\",\"text\":\"Deploy concluído\"}]}"}],"isError":false}}
```

`tools/call → voices`:

```json
→ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"voices","arguments":{}}}
← {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"{\"voices\":[{\"engine\":\"say\",\"name\":\"Luciana\",...},{\"engine\":\"piper\",\"name\":\"pt_BR-faber-medium\",...}]}"}],"isError":false}}
```

Tool error path — daemon not running:

```json
→ {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"queue","arguments":{}}}
← {"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"daemon not running"}],"isError":true}}
```

## Claude Code walkthrough

1. Build + install agent-tts:
   ```bash
   zig build -Doptimize=ReleaseFast
   cp zig-out/bin/agent-tts /opt/homebrew/bin/
   agent-tts daemon install   # autostart at login
   ```
2. Register the MCP server:
   ```bash
   ./scripts/install-mcp.sh
   ```
3. Restart Claude Code. New tools `say`, `queue`, `skip`, `clear`, `voices` show up under the `agent-tts` server.
4. Ask Claude to use one: *"Use the say tool to read this paragraph in Portuguese."* No shell prompt, no permission dance per call.

The daemon does the actual synthesis — the MCP server is a stateless bridge. Killing the MCP process between calls is fine; Claude Code spawns one per session.

## Honest deferrals

| Capability | Status | Why |
|------------|--------|-----|
| `prompts/*` | not implemented | voice agents do not need prompt templates |
| `resources/*` | not implemented | the daemon owns no addressable content |
| `sampling/*` | not implemented | nothing in agent-tts asks the LLM to think |
| `logging/*` | not implemented | daemon logs land in `~/.cache/agent-tts/daemon.*.log` already |
| `notifications/tools/list_changed` | declared off (`listChanged: false`) | tool list never changes mid-session |
| `skip(id)` | argument accepted, ignored | the daemon's SKIP only targets the head; v1.6 will route by id |
| `voices` enumerating all installed `say` voices | hardcoded to Luciana + Felipe | `say -v ?` would cost a process per call; v1.6 |
| End-to-end test against a real Claude Code | not measured | scaffolded via `echo \| agent-tts mcp` smoke tests; full client validation deferred |

## Related

- [Architecture](/agent-tts/arquitetura/) — MCP server slots into "Components"
- [Changelog](/agent-tts/changelog/) — v1.5 entry has the install snippet and the binary-size delta
- [MCP spec](https://modelcontextprotocol.io/specification/2024-11-05) — the protocol agent-tts speaks

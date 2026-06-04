# docsync-feature lead-time

- start_ts: 1780579336
- end_ts: 1780579616
- elapsed_seconds: 280
- elapsed_human: ~4m40s
- branch: agent-tts/docs-feature
- worktree: /tmp/at-docs-c/99-development/agent-tts
- scope: src/content/docs/{mcp.md,menubar.md,playground.mdx}
- target: sync to v1.10.13 (13 MCP tools, guided clone, honest playground)
- npm_build: exit 0 (10 pages built in 3.74s, pagefind index OK)
- tools_audited: 13 (vs `src/mcp.zig::buildToolsListResponse`)
  - say, queue, skip, clear, voices, say_stream, pause, resume, replay, history, synth_voice_test, voice_knob_search, tech_profile_search
- changes:
  - mcp.md: rewrote 13-tool table, dropped HEAD/v1.10.12 merge-conflict markers, added install snippet block + `claude mcp add` form, documented tech_profile_search 4 profiles × 2 postfx matrix with knob anchors, postfx enum, v1.10.13 postfx-watchdog note
  - menubar.md: TL;DR + install updated, v1.10.3 guided-clone section gained v1.10.4 (staged WAV diagnostic + Show in Finder) and v1.10.5 (absolute path resolution) subsections, voice picker honesty re: tech knobs not exposed, floating player pause/resume single-button noted, deferred-list trimmed (removed "deferred to v1.10.1" lines that already landed), added tech-profile-knobs honest scope row
  - playground.mdx: title/description retracted v1.10.2 promise, WASM synth deferred indefinitely, banner says "unchanged v1.10.1 → v1.10.13", added prominent callout linking to MCP tech_profile_search as real A/B discovery loop, head <link>+<script defer> kept verbatim
- cross-page TODOs: none — used /agent-tts/<page>/ URL form for the one cross-page anchor (mcp → tech_profile_search hash from playground; menubar → mcp tech_profile_search hash)

# docsync arquitetura+motor — lead time

- start: 1780579304 (epoch)
- end:   1780579693 (epoch)
- elapsed: 389 s (6 min 29 s)
- agent: docs-arch (worktree /tmp/at-docs-b)
- scope: src/content/docs/arquitetura.md + src/content/docs/motor.md
- target: v1.10.13
- branch: agent-tts/docs-arch

## Subsections landed

### arquitetura.md
- IPC wire: 10-field shape + backward-compat parse rule (peek table) + new player ops (HISTORY/PAUSE/RESUME/REPLAY)
- Queue schema: full v1.10.10 column set (10 cols + index) + migration history + NULL sentinel rule + cadence-not-a-column note
- Engine routing: postfx funnel pointer (`playWithPostfx`)
- Post-fx pipeline (v1.10.10+): NEW H3 subsection — diagram, profiles, fall-back rule, v1.10.13 pipe-deadlock fix + watchdog
- Logging & observability: worker resilience (`defer finishPlaying`) + honest scope on synth watchdog
- Code layout: refreshed listing — log.zig, postfx.zig, ssml.zig, stream.zig, voice.zig, root.zig

### motor.md
- Identifier normalization (v1.10.9+): NEW H3 — explicit rule table + conservatism notes
- Profiles (v1.10.10+): NEW H2 — four bundles (tech / stock-tech / broadcast / expressive) with full knob table + cadence gating + postfx pairing
- Audio post-fx: NEW H3 "Pipe-deadlock fix + 5 s watchdog (v1.10.13)" — three-thread design + watchdog env knob + queue-advances-anyway link

## Build
- `npm install` clean (217 packages)
- `npm run build` → 10 pages built in 5.44 s — green
- arquitetura/index.html + motor/index.html contain "Post-fx pipeline", "Profiles (v1.10.10", "Pipe-deadlock", "Identifier normalization", "v1.10.13"

## Cross-page TODOs left for sibling agents
- None. Section names referenced cross-page use the `/agent-tts/<page>/` URL form per the Starlight gotcha (no autoprefix on MDX body links).

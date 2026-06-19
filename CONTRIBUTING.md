# Contributing to ptah

Thanks for hacking on a Pt-BR TTS CLI. Inner loop is fast, KPI is real, scope is tight.

## Setup

Requires:
- macOS 13+ (arm64 preferred; x86_64 cross-compile works)
- [Zig 0.16](https://ziglang.org) (`brew install zig` or zigup)
- Node 22+ for the docs site (`npm` ships with Node)

```bash
git clone https://github.com/biliboss/ptah.git
cd ptah
zig build                  # debug
zig build test --summary all
```

To work on the Kokoro engine, build the vendored Kokoro.dylib once:

```bash
./scripts/build-Kokoro.sh        # clones + cmake build (~10 min cold)
./scripts/fetch-voice.sh           # downloads pt_BR-faber-medium.onnx
zig build -Doptimize=ReleaseFast -Dwith-piper=true
```

## Inner loop

| Command | What it does |
|---------|--------------|
| `zig build` | debug build → `zig-out/bin/ptah` |
| `zig build -Doptimize=ReleaseFast` | release build, ~918KB without piper, ~975KB with |
| `zig build test --summary all` | 27 tests (preproc + root + launchd) |
| `zig fmt --check src build.zig` | lint |
| `zig build universal` | arm64 + x86_64 fused via `lipo -create` |
| `zig build bench-preproc` | microbench preprocessor (1000 iter per case) |
| `npm run dev` | Astro docs at `ptah.test` via puma-dev (random port) |
| `npm run build` | static docs → `dist/` |

## File layout

```
src/
  main.zig         # entry, argv routing
  client.zig       # enqueue / queue / skip / clear subcommands
  daemon.zig       # accept loop + worker + engine routing
  queue.zig        # SQLite WAL queue
  ipc.zig          # wire protocol (line-delimited TSV)
  tts.zig          # spawn `say`
  piper.zig        # Kokoro FFI (GPL-3.0-or-later)
  audio.zig        # afplay.Engine wrapper for PCM streaming
  preproc.zig      # Pt-BR abbreviations + cardinals + pauses
  launchd.zig      # LaunchAgent install/uninstall/status
  content/docs/    # Starlight docs site
vendor/
  afplay/          # (gitignored) afplay C wrapper
  README.md        # vendor build recipe
_qa/               # baselines per version (v0.1 → v1.0)
Formula/           # brew tap stub
.github/workflows/ # CI + docs deploy
```

## KPI

**Time-to-first-audio (TTFA)**. Every PR must explain (or measure) its TTFA impact. We accept code that doesn't move TTFA (refactor, docs) but reject "improvements" that regress it.

Baselines: `_qa/vX.Y-baseline.md`. New benchmarks go there too.

## Tests

```bash
zig build test --summary all
```

Tests live next to the code (`test "..."` blocks in `*.zig`). The preprocessor has 26 unit tests covering every transform + edge cases (empty, only punctuation, mid-word abbreviations, out-of-range numbers).

A PR that adds a transform must add at least one test per case.

## SPDX

Every `.zig` file starts with one of:

```zig
// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-License-Identifier: GPL-3.0-or-later  // only for files that link Kokoro
```

New files must include the header. New deps must clear license review (no closed-source, no AGPL).

## Commit messages

Conventional commits. Subject ≤72 chars. Body explains the "why" if not obvious.

```
feat(audio): pin source sample_rate so Faber 22050Hz plays at correct pitch

afplay AudioBuffer.Config defaulted to engine output rate (48000), which
upsampled the buffer by ~2.18× — pitch shifted up.
```

## Pull requests

- Run `zig build test`, `zig fmt --check`, and the smoke daemon flow before pushing.
- Update `_qa/vX.Y-baseline.md` or add a new one if your change affects measurements.
- Update `src/content/docs/changelog.md` for user-facing changes.
- Link a related issue if one exists.
- One concern per PR. Split refactors from features.

## Security

See [SECURITY.md](./SECURITY.md). TL;DR: report via private GitHub security advisory, not public issues.

## Code of Conduct

[Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Be excellent.

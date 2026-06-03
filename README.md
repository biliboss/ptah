# agent-tts — Pt-BR TTS CLI for macOS

Single Zig binary. Daemon + SQLite WAL queue. Default engine is `say -v Luciana`; optional libpiper FFI engine for higher quality at higher cold cost.

KPI: time-to-first-audio (TTFA). v1.0 alvo: < 300ms `say` quente, < 1s libpiper warm.

## Install

### Via brew tap (v1.0+)

The tap repo `gabriel/tap` is a placeholder — replace with the real
tap when published.

```bash
brew tap gabriel/tap
brew install gabriel/tap/agent-tts
```

`brew install` lands the universal Mach-O (arm64 + x86_64) into
`$(brew --prefix)/bin/agent-tts`. Verify:

```bash
file $(brew --prefix)/bin/agent-tts
# Mach-O universal binary with 2 architectures: ...
agent-tts --version
# agent-tts 1.0.0
```

### From source

Requires Zig 0.16 (`brew install zig` or zigup).

```bash
git clone https://github.com/gabriel/agent-tts.git
cd agent-tts
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/agent-tts /usr/local/bin/
```

Universal binary:

```bash
zig build universal
# Produces zig-out/bin/agent-tts-universal (arm64 + x86_64).
file zig-out/bin/agent-tts-universal
```

### Auto-start at login

```bash
agent-tts daemon install      # writes ~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist
agent-tts daemon status       # prints launchd load state
agent-tts daemon uninstall    # removes the LaunchAgent
```

### Optional libpiper engine

Off by default — keeps the universal binary small. Build the vendor
libpiper.dylib first (see [`vendor/README.md`](./vendor/README.md)), then:

```bash
zig build -Doptimize=ReleaseFast -Dwith-piper=true
```

Voice file expected at `~/.cache/agent-tts/voices/pt_BR-faber-medium.onnx`.

## Usage

```bash
agent-tts "olá mundo"           # enqueue on running daemon
agent-tts queue                 # list pending + playing items
agent-tts skip                  # skip current item
agent-tts clear                 # drop all pending items
agent-tts --voice "Felipe" "..."
agent-tts --rate 220 "..."
agent-tts --help
```

Daemon listens on a UNIX socket at `~/.cache/agent-tts/sock` and persists the queue at `~/.cache/agent-tts/queue.db`.

## Docs site

The Astro Starlight site under `src/content/docs/` covers architecture, engine choice, roadmap and per-version measurements. Run locally:

```bash
npm install
npm run dev
```

Conventions and contribution rules in [`AGENTS.md`](./AGENTS.md).

# AGENTS.md — ptah docs

Astro Starlight site documenting the **ptah** project (global Zig CLI for Pt-BR TTS on macOS).

## Purpose

Source of truth for decisions, architecture, and roadmap. Audience: maintainers + Claude Code agents who will evolve the project.

## Single KPI

**Time-to-first-audio (TTFA)**: latency between `ptah "x"` and the first audible sample. Every decision is justified against this metric. v1.0 target: < 300ms warm, < 800ms cold.

## Structure (flat, 4 pages)

```
src/content/docs/
  index.mdx       # Splash + KPI + constraints
  arquitetura.md  # CLI+daemon, IPC socket, SQLite queue, pacing
  motor.md        # TTS comparison + why we picked say Premium Luciana
  roadmap.md      # Milestones v0.1 → v1.0 + how we measure the KPI
```

No subdirs. No sidebar groups. Add a new page only when a new decision doesn't fit any existing one.

## Run locally

```bash
npm install
npm run dev          # random port + puma-dev sync
npm run dev:fixed    # fixed port 4321 (debug)
```

`npm run dev` (defined in `scripts/dev.mjs`):

1. Asks the kernel for a free port (`net.createServer().listen(0)` → close → inherit the number)
2. Writes `~/.puma-dev/ptah` with the drawn port (if puma-dev exists)
3. `spawn('astro', ['dev', '--port', port])`
4. SIGINT/SIGTERM → cleans the puma-dev file before exiting

Zero port conflicts. Stable public URL (`http://ptah.test`), with the port behind it changing every run.

Static build:

```bash
npm run build
npm run preview
```

## Local DNS access (puma-dev)

Project standard for local dev servers: **puma-dev** (~10MB Go binary, launchd, `/etc/resolver/test`). Maps `ptah.test:80 → localhost:<random-port>` automatically.

One-time setup per machine:

```bash
brew install puma/puma/puma-dev
sudo puma-dev -setup       # creates /etc/resolver/test
puma-dev -install          # registers launchd
```

No manual per-project command — `npm run dev` writes `~/.puma-dev/ptah` with the right port every time.

Stop/remove:

```bash
puma-dev -uninstall                  # removes launchd globally
rm ~/.puma-dev/ptah             # removes just this project (npm run dev cleans up on SIGINT)
```

Why random port + puma-dev:

- Random port = zero conflicts when running 3 projects in parallel
- puma-dev = fixed URL for bookmarks, history, browser, screenshots
- Auto-sync in `dev.mjs` = no need to remember editing `~/.puma-dev/<app>` by hand

## Page conventions

- **Minimum frontmatter**: `title`, `description`
- **TL;DR at the top**: 1 paragraph before any section
- **Tables > prose** for tradeoffs, metrics, comparisons
- **Plain Markdown** (`.md`). MDX (`.mdx`) only on the index (needs Card/CardGrid)
- **No decorative emoji**. Only ✅/⚠️/❌ in evaluation tables
- **Every decision needs a justification tied to the KPI** — if it doesn't move TTFA, it doesn't belong in the doc

## Adding a page

1. Create `src/content/docs/<slug>.md`
2. Add it to the `sidebar` in `astro.config.mjs`
3. Link it from the related page
4. Run `npm run dev` and check the render

## Documented project stack

Locked summary (details on the pages):

- **Language**: Zig 0.14+ (binary < 2MB, native Apple Silicon)
- **TTS engine**: macOS `say` with the "Luciana (Premium)" voice
- **Architecture**: single binary, client mode + daemon mode
- **IPC**: UNIX socket at `~/.cache/ptah/sock`
- **Queue**: SQLite WAL at `~/.cache/ptah/queue.db`
- **Install path**: `/usr/local/bin/ptah`
- **Auto-start**: `launchd` plist `~/Library/LaunchAgents/io.github.biliboss.ptah.plist`

## Don't do (docs)

- Don't duplicate content across pages — link instead
- PRs must pass CI before merge
- Don't embed diagrams as images — use ASCII code fences (searchable + diff-friendly)
- Don't pad pages with decorative prose — cut anything that doesn't move a decision

## Related

- Live docs: https://biliboss.github.io/ptah/
- Repo README: [`README.md`](./README.md)
- Changelog: [`src/content/docs/changelog.md`](./src/content/docs/changelog.md)

## Starlight gotchas

- Starlight 0.30+ uses `social: {}` (no longer an array)
- MDX only in `.mdx` — plain markdown = `.md`. Mixing breaks the build
- CustomCSS must live in `src/styles/` and be referenced in `astro.config.mjs`
- Sidebar `link` needs a trailing slash (`/motor/` not `/motor`)

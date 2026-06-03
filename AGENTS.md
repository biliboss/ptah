# AGENTS.md — agent-tts docs

Astro Starlight site documentando o projeto **agent-tts** (Zig CLI global pra TTS Pt-BR no macOS).

## Propósito

Documento vivo de decisões, arquitetura e roadmap. Audiência: Gabriel + agentes (Claude Code) que vão evoluir o projeto.

## KPI único

**Time-to-first-audio (TTFA)**: latência entre `agent-tts "x"` e primeiro sample audível. Toda decisão se justifica contra essa métrica. Alvo v1.0: < 300ms quente, < 800ms cold.

## Estrutura (flat, 4 páginas)

```
src/content/docs/
  index.mdx       # Splash + KPI + restrições
  arquitetura.md  # CLI+daemon, IPC socket, fila SQLite, cadência
  motor.md        # Comparativo TTS + escolha say Premium Luciana
  roadmap.md      # Marcos v0.1 → v1.0 + medição do KPI
```

Sem subdir. Sem grupos no sidebar. Adicionar página só quando uma decisão nova não couber em nenhuma existente.

## Rodar local

```bash
npm install
npm run dev          # porta random + sync puma-dev
npm run dev:fixed    # porta 4321 fixa (debug)
```

`npm run dev` (definido em `scripts/dev.mjs`):

1. Pede porta livre ao kernel (`net.createServer().listen(0)` → fecha → herda o número)
2. Escreve `~/.puma-dev/agent-tts` com a porta sorteada (se puma-dev existe)
3. `spawn('astro', ['dev', '--port', porta])`
4. SIGINT/SIGTERM → limpa o arquivo do puma-dev antes de sair

Zero conflito de porta. URL pública estável (`http://agent-tts.test`), porta atrás dela muda a cada run.

Build estático:

```bash
npm run build
npm run preview
```

## Acesso via DNS local (puma-dev)

Padrão do vault pra dev servers locais: **puma-dev** (~10MB Go binary, launchd, `/etc/resolver/test`). Mapeia `agent-tts.test:80 → localhost:<porta-random>` automático.

Setup uma vez por máquina:

```bash
brew install puma/puma/puma-dev
sudo puma-dev -setup       # cria /etc/resolver/test
puma-dev -install          # registra launchd
```

Sem comando manual por projeto — `npm run dev` já escreve `~/.puma-dev/agent-tts` com a porta certa toda vez.

Stop/remove:

```bash
puma-dev -uninstall                  # remove launchd geral
rm ~/.puma-dev/agent-tts             # remove só este projeto (npm run dev limpa sozinho no SIGINT)
```

Por que random port + puma-dev:

- Random port = zero conflito quando rodo 3 projetos em paralelo
- puma-dev = URL fixa pra bookmark, history, browser, screenshot
- Sync automático no `dev.mjs` = sem lembrar de editar `~/.puma-dev/<app>` na mão

## Convenções de página

- **Frontmatter mínimo**: `title`, `description`
- **TL;DR no topo**: 1 parágrafo antes de qualquer seção
- **Tabelas > prosa** pra tradeoffs, métricas, comparativos
- **Markdown puro** (`.md`). MDX (`.mdx`) só na index (precisa de Card/CardGrid)
- **Sem emoji decorativo**. Só ✅/⚠️/❌ em tabelas de avaliação
- **Cada decisão precisa de justificativa amarrada ao KPI** — se não move TTFA, sai do doc

## Como adicionar página

1. Cria `src/content/docs/<slug>.md`
2. Adiciona ao `sidebar` em `astro.config.mjs`
3. Linka da página relacionada
4. Roda `npm run dev` e checa render

## Stack do projeto documentado

Resumo travado (detalhe nas páginas):

- **Linguagem**: Zig 0.14+ (binary < 2MB, nativo Apple Silicon)
- **Motor TTS**: macOS `say` com voz "Luciana (Premium)"
- **Arquitetura**: single binary, modo client + modo daemon
- **IPC**: UNIX socket em `~/.cache/agent-tts/sock`
- **Fila**: SQLite WAL em `~/.cache/agent-tts/queue.db`
- **Install path**: `/usr/local/bin/agent-tts`
- **Auto-start**: `launchd` plist `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist`

## Não fazer (docs)

- Não duplicar conteúdo entre páginas — linka
- Não publicar externamente sem aprovação do Gabriel
- Não embedar diagramas em imagem — usa code fence ASCII (busca + diff friendly)
- Não inflar páginas com prosa decorativa — corta tudo que não move decisão

## Conexão com vault

- PARA entry: `03-projects/agent-tts.md`
- Memória: `_memory/project-agent-tts.md`
- Código (futuro): mesmo diretório, `src/main.zig` etc.

## Gotchas Starlight

- Starlight 0.30+ usa `social: {}` (não mais array)
- MDX só na `.mdx` — markdown puro = `.md`. Mistura quebra
- CustomCSS precisa estar em `src/styles/` e referenciado em `astro.config.mjs`
- Sidebar `link` precisa de trailing slash (`/motor/` não `/motor`)

# agent-tts — docs

Docs site interno (Astro Starlight) do projeto **agent-tts** — CLI global em Zig que enfileira texto pra Text-to-Speech Pt-BR no macOS.

## Rodar local

```bash
npm install
npm run dev
```

`npm run dev` pega porta livre do kernel (zero conflito) e sincroniza com puma-dev:

```
puma-dev → http://agent-tts.test  (proxy → :54213)
```

URL fixa, porta atrás dela muda a cada run. Sem puma-dev instalado, script printa `http://localhost:<porta>` e segue normal.

Forçar porta 4321 (debug):

```bash
npm run dev:fixed
```

Setup puma-dev: ver [AGENTS.md](./AGENTS.md).

## Estrutura

```
src/content/docs/
  index.mdx       # Splash + KPI (time-to-first-audio)
  arquitetura.md  # CLI+daemon, IPC, fila, cadência
  motor.md        # Comparativo TTS, escolha `say` Premium Luciana
  roadmap.md      # v0.1 → v1.0, instalação, medição do KPI
```

Convenções de contribuição: ver [AGENTS.md](./AGENTS.md).

## Documento vivo

Atualiza marco a marco conforme medimos TTFA real. Decisões só viram lei depois de número publicado.

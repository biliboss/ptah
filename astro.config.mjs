import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages deployment lives at https://biliboss.github.io/agent-tts/
// Override with the SITE / BASE env vars for staging or custom domains.
const SITE = process.env.SITE || 'https://biliboss.github.io';
const BASE = process.env.BASE || '/agent-tts';

export default defineConfig({
  site: SITE,
  base: BASE,
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'agent-tts',
      description: 'Zig CLI global pra TTS Pt-BR no macOS. KPI: tempo até começar a ouvir.',
      customCss: ['./src/styles/custom.css'],
      social: {
        github: 'https://github.com/biliboss/agent-tts',
      },
      editLink: {
        baseUrl: 'https://github.com/biliboss/agent-tts/edit/main/',
      },
      sidebar: [
        { label: 'Visão', link: '/' },
        { label: 'Arquitetura', link: '/arquitetura/' },
        { label: 'Motor TTS', link: '/motor/' },
        { label: 'Roadmap', link: '/roadmap/' },
        { label: 'Changelog', link: '/changelog/' },
      ],
    }),
  ],
});

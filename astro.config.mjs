import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages deployment lives at https://biliboss.github.io/ptah/
// Override with the SITE / BASE env vars for staging or custom domains.
const SITE = process.env.SITE || 'https://biliboss.github.io';
const BASE = process.env.BASE || '/ptah';

export default defineConfig({
  site: SITE,
  base: BASE,
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'ptah',
      description: 'Ptah — Zig CLI for Pt-BR TTS on macOS. KPI: time-to-first-audio.',
      logo: {
        src: './public/logos/ptah-logo.png',
        replacesTitle: false,
      },
      favicon: '/favicon.ico',
      customCss: ['./src/styles/custom.css'],
      social: {
        github: 'https://github.com/biliboss/ptah',
      },
      editLink: {
        baseUrl: 'https://github.com/biliboss/ptah/edit/main/',
      },
      sidebar: [
        { label: 'Overview', link: '/' },
        { label: 'Architecture', link: '/arquitetura/' },
        { label: 'TTS engine', link: '/motor/' },
        { label: 'Roadmap', link: '/roadmap/' },
        { label: "What's next", link: '/whats-next/' },
        { label: 'MCP server', link: '/mcp/' },
        { label: 'Playground', link: '/playground/' },
        { label: 'Menubar UI', link: '/menubar/' },
        { label: 'Changelog', link: '/changelog/' },
      ],
    }),
  ],
});

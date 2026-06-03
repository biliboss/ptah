import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'agent-tts',
      description: 'Zig CLI global pra TTS Pt-BR no macOS. KPI: tempo até começar a ouvir.',
      customCss: ['./src/styles/custom.css'],
      social: {},
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

import { defineConfig, devices } from '@playwright/test';

// Default target: live Pages URL. Override with E2E_BASE_URL for staging
// or local preview (e.g. http://localhost:4321).
// Trailing slash matters: Playwright's URL resolution treats paths starting
// with `/` as origin-absolute, so `/arquitetura/` against
// `https://biliboss.github.io/agent-tts` would drop the `/agent-tts` base.
// With a trailing slash on the baseURL and relative paths in tests, the
// Starlight `base: '/agent-tts'` is preserved.
const baseURL = process.env.E2E_BASE_URL || 'https://biliboss.github.io/agent-tts/';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});

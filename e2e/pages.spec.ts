import { test, expect } from '@playwright/test';

// Paths are RELATIVE to baseURL (which ends in /agent-tts/). A leading slash
// would escape the base path — see playwright.config.ts for the rationale.
const pages = [
  { path: '',              h1: /agent-tts/i,    splash: true },
  { path: 'arquitetura/',  h1: /Arquitetura/,   splash: false },
  { path: 'motor/',        h1: /Motor TTS/,     splash: false },
  { path: 'roadmap/',      h1: /Roadmap/,       splash: false },
  { path: 'changelog/',    h1: /Changelog/,     splash: false },
];

const navEntries = ['Visão', 'Arquitetura', 'Motor TTS', 'Roadmap', 'Changelog'];

for (const p of pages) {
  test(`/${p.path} renders with the expected H1`, async ({ page }) => {
    const res = await page.goto(p.path);
    expect(res?.status(), `HTTP status for ${p.path}`).toBeLessThan(400);

    await expect(page.locator('h1').first()).toContainText(p.h1);

    // Splash template (home only) hides the sidebar by design. Doc-template
    // pages must expose every canonical entry — guards against config drift.
    if (!p.splash) {
      for (const entry of navEntries) {
        await expect(page.locator('nav.sidebar').getByRole('link', { name: entry }).first())
          .toBeVisible({ timeout: 5_000 });
      }
    }
  });
}

test('base path is /agent-tts (root /arquitetura/ must 404)', async ({ page }) => {
  // Guards against an accidental `base: '/'` regression in astro.config.mjs.
  const res = await page.goto('https://biliboss.github.io/arquitetura/');
  expect(res?.status()).toBe(404);
});

test('pagefind search index is reachable', async ({ page }) => {
  // Starlight ships Pagefind under <base>/pagefind/. If it 404s the search
  // box at the top of every page silently breaks.
  const res = await page.request.get('pagefind/pagefind.js');
  expect(res.status(), 'pagefind script reachable').toBeLessThan(400);
});

test('changelog leads with the v1.0 ship entry', async ({ page }) => {
  await page.goto('changelog/');
  // Changelog renders headings as ## v1.0 ... — Starlight maps them to h2.
  await expect(page.getByRole('heading', { name: /v1\.0/i }).first()).toBeVisible();
});

test('home links to the architecture page', async ({ page }) => {
  await page.goto('');
  // Splash hero + CardGrid both link there. .first() picks whichever comes
  // first in DOM order; either is fine.
  const link = page.getByRole('link', { name: /arquitetura/i }).first();
  await expect(link).toBeVisible();
  await link.click();
  await expect(page).toHaveURL(/\/agent-tts\/arquitetura\/?$/);
});

test('every doc page has an edit-on-github link', async ({ page }) => {
  // editLink.baseUrl in astro.config.mjs is the OSS contribution invite.
  await page.goto('arquitetura/');
  const edit = page.getByRole('link', { name: /edit page/i }).first();
  await expect(edit).toBeVisible();
  await expect(edit).toHaveAttribute('href', /github\.com\/biliboss\/agent-tts\/edit\/main/);
});

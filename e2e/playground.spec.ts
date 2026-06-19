// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ptah v1.9 — playground widget e2e.
//
// Targets the same base URL as pages.spec.ts (relative paths resolved against
// playwright.config.ts baseURL). Asserts the page renders, the voice picker
// has all four entries, and the Speak click surfaces the 501 "WASM build
// pending" message that v1.9 intentionally ships.
import { test, expect } from '@playwright/test';

test.describe('/playground/ (v1.9 scaffold)', () => {
  test('page loads with the expected H1 and sidebar entry', async ({ page }) => {
    const res = await page.goto('playground/');
    expect(res?.status(), 'HTTP status').toBeLessThan(400);

    await expect(page.locator('h1').first()).toContainText(/Playground/i);
    await expect(
      page.locator('nav.sidebar').getByRole('link', { name: 'Playground' }).first()
    ).toBeVisible();
  });

  test('voice dropdown lists four entries', async ({ page }) => {
    await page.goto('playground/');
    const options = page.locator('.ptah-playground select [data-role="voice"]');
    // Querying the <select> itself is simpler — count its <option> children.
    const optionCount = await page.locator('.ptah-playground select option').count();
    expect(optionCount, 'four voice options').toBe(4);

    const values = await page.locator('.ptah-playground select option').evaluateAll(
      (els) => els.map((e) => (e as HTMLOptionElement).value)
    );
    expect(values).toEqual(['faber', 'luciana', 'felipe', 'amy']);
  });

  test('text input + Speak button are visible', async ({ page }) => {
    await page.goto('playground/');
    await expect(page.locator('.ptah-playground textarea')).toBeVisible();
    await expect(page.locator('.ptah-playground textarea')).not.toBeDisabled();
    await expect(page.getByRole('button', { name: /speak/i })).toBeVisible();
  });

  test('clicking Speak surfaces the 501 pending message', async ({ page }) => {
    await page.goto('playground/');

    // Sanity — status starts neutral.
    await expect(page.locator('[data-role="status"]').first()).toContainText(/Pronto/);

    await page.getByRole('button', { name: /speak/i }).click();

    // The static stub at public/api/synth.html carries the sentinel marker;
    // the widget reads it and renders the "WASM build pending" copy.
    const status = page.locator('[data-role="status"]').first();
    await expect(status).toContainText(/501/, { timeout: 10_000 });
    await expect(status).toContainText(/WASM build pending/i);
    await expect(status).toContainText(/v1\.9\.1/i);
  });
});

import { test, expect } from '@playwright/test';

test.describe('Wave 11: GitHub-Only Zero-Account Distribution & Maker Tools', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to local CAD application
    await page.goto('/');
    await page.waitForSelector('#cad-canvas', { state: 'visible' });
    await page.waitForFunction(() => window.__cadViewer !== undefined);
  });

  test('Test 1: Embed Mode & URL Hash Auto-Loader renders clean viewport and parameter sliders', async ({ page }) => {
    // Encode sample parametric model: export const params = { width: 4.5, height: 3.0, depth: 1.5 };
    const sampleCode = `export const params = {\n  width: 4.5,\n  height: 3.0,\n  depth: 1.5\n};\nexport function main() {\n  return box(params.width, params.height, params.depth);\n}`;
    const encoded = Buffer.from(sampleCode).toString('base64');

    // Load with ?embed=true and #code=
    await page.goto(`/?embed=true#code=${encoded}`);
    await page.waitForSelector('#cad-canvas', { state: 'visible' });

    // Verify embed-mode class applied to body
    const bodyClass = await page.evaluate(() => document.body.className);
    expect(bodyClass).toContain('embed-mode');

    // Verify top ribbon is hidden in embed mode
    const ribbonVisible = await page.evaluate(() => {
      const el = document.getElementById('top-ribbon-container');
      return el ? window.getComputedStyle(el).display !== 'none' : false;
    });
    expect(ribbonVisible).toBe(false);

    // Verify Parameter Sliders panel is visible and contains parameters
    const slidersPanel = page.locator('[data-testid="parameter-sliders-panel"]');
    await expect(slidersPanel).toBeVisible();

    // Verify individual sliders
    const widthSlider = page.locator('[data-testid="param-slider-width"]');
    await expect(widthSlider).toBeVisible();
    expect(await widthSlider.inputValue()).toBe('4.5');

    const heightSlider = page.locator('[data-testid="param-slider-height"]');
    await expect(heightSlider).toBeVisible();
    expect(await heightSlider.inputValue()).toBe('3');

    // Test slider interaction: change width to 5.0
    await widthSlider.evaluate((el: HTMLInputElement) => {
      el.value = '5.0';
      el.dispatchEvent(new Event('input', { bubbles: true }));
    });

    const widthVal = await page.locator('#param-val-width').textContent();
    expect(widthVal).toBe('5');

    // Verify active script was updated live
    const activeScript = await page.evaluate(() => window.__getActiveCodeScript?.());
    expect(activeScript).toContain('width: 5');

    // Verify download buttons exist in maker panel
    await expect(page.locator('[data-testid="btn-maker-download-step"]')).toBeVisible();
    await expect(page.locator('[data-testid="btn-maker-download-3mf"]')).toBeVisible();
    await expect(page.locator('[data-testid="btn-maker-download-dxf"]')).toBeVisible();
  });

  test('Test 2: One-Click Share & Embed Modal generates direct URL, Web Component snippet & Portable HTML', async ({ page }) => {
    // 1. Verify Top Ribbon has Share button
    const shareBtn = page.locator('[data-testid="btn-share-embed"]');
    await expect(shareBtn).toBeVisible();

    // 2. Click Share button
    await shareBtn.click();

    // 3. Verify Share modal opens
    const modal = page.locator('[data-testid="share-embed-modal"]');
    await expect(modal).toBeVisible();

    // 4. Verify Direct Share URL contains #code=
    const directUrlInput = page.locator('#share-direct-url');
    await expect(directUrlInput).toBeVisible();
    const urlValue = await directUrlInput.inputValue();
    expect(urlValue).toContain('#code=');

    // 5. Verify <opencad-viewer> Web Component embed snippet
    const embedCodeTextarea = page.locator('#share-embed-code');
    await expect(embedCodeTextarea).toBeVisible();
    const snippetValue = await embedCodeTextarea.inputValue();
    expect(snippetValue).toContain('opencad-element.mjs');
    expect(snippetValue).toContain('<opencad-viewer');
    expect(snippetValue).toContain('sliders="true"');

    // 6. Test Copy Link button
    const copyUrlBtn = page.locator('[data-testid="btn-copy-url"]');
    await expect(copyUrlBtn).toBeVisible();
    await copyUrlBtn.click();
    await expect(copyUrlBtn).toHaveText(/Copied!|Copy Link/);

    // 7. Verify Offline Portable HTML Download button
    const portableBtn = page.locator('[data-testid="btn-download-portable"]');
    await expect(portableBtn).toBeVisible();

    // 8. Close modal
    const closeBtn = page.locator('#btn-close-share-modal');
    await closeBtn.click();
    await expect(modal).toBeHidden();
  });

  test('Test 3: Starter Template auto-populates parameter sliders and handles message events', async ({ page }) => {
    // Load CNC bracket template
    await page.evaluate(() => window.__loadTemplate?.('template-cnc-bracket'));
    await page.waitForTimeout(500);

    // Verify sliders panel populated
    const slidersPanel = page.locator('[data-testid="parameter-sliders-panel"]');
    await expect(slidersPanel).toBeVisible();

    // Post custom message to simulate parent iframe interaction
    await page.evaluate(() => {
      window.postMessage({
        type: 'OPENCAD_SET_CODE',
        code: 'const params = { length: 80, thickness: 12 };\nbox(params.length, params.thickness, 20);'
      }, '*');
    });

    await page.waitForTimeout(500);

    const lengthSlider = page.locator('[data-testid="param-slider-length"]');
    await expect(lengthSlider).toBeVisible();
    expect(await lengthSlider.inputValue()).toBe('80');
  });
});

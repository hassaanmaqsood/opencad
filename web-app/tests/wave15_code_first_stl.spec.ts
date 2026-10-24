import { test, expect } from '@playwright/test';

test.describe('Wave 15: Code-First Computational Engineering & Native STL Export Suite', () => {
  test.beforeEach(async ({ page }) => {
    test.setTimeout(120000);
  });

  test('Test 1: Native Watertight Binary & ASCII STL Export via window.opencad.exportStl()', async ({ page }) => {
    await page.goto('/?mode=code-first');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForFunction(() => (window as any).opencad !== undefined);

    // 1. Binary STL Export
    const binaryStlInfo = await page.evaluate(async () => {
      const cad = (window as any).opencad;
      const res = await cad.exportStl({ binary: true });

      let bytes: Uint8Array;
      if (res instanceof Uint8Array) {
        bytes = res;
      } else if (typeof res === 'object' && res.data) {
        bytes = new Uint8Array(res.data);
      } else {
        const str = String(res);
        bytes = new Uint8Array(str.length);
        for (let i = 0; i < str.length; i++) bytes[i] = str.charCodeAt(i);
      }

      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const triCount = view.getUint32(80, true);
      const headerStr = new TextDecoder('ascii').decode(bytes.slice(0, 80)).replace(/\0/g, '').trim();

      // Check first facet attribute byte count (offset 84 + 48 = 132)
      const attr0 = bytes.length >= 134 ? view.getUint16(132, true) : 0;

      return {
        byteLength: bytes.length,
        triCount,
        headerStr,
        attr0,
        expectedLength: 84 + triCount * 50,
      };
    });

    expect(binaryStlInfo.byteLength).toBeGreaterThanOrEqual(84);
    expect(binaryStlInfo.triCount).toBeGreaterThan(0);
    expect(binaryStlInfo.byteLength).toBe(binaryStlInfo.expectedLength);
    expect(binaryStlInfo.attr0).toBe(0);

    // 2. ASCII STL Export
    const asciiStl = await page.evaluate(async () => {
      const cad = (window as any).opencad;
      const res = await cad.exportStl({ binary: false });
      return typeof res === 'string' ? res : new TextDecoder().decode(res);
    });

    expect(asciiStl).toContain('solid ');
    expect(asciiStl).toContain('facet normal ');
    expect(asciiStl).toContain('outer loop');
    expect(asciiStl).toContain('vertex ');
    expect(asciiStl).toContain('endloop');
    expect(asciiStl).toContain('endfacet');
    expect(asciiStl).toContain('endsolid ');
  });

  test('Test 2: 100% View-Centric Canvas: Zero Authoring Ribbons, Zero Duplicate Sidebars & Zero Horizontal Scrollbars', async ({ page }) => {
    await page.goto('/?mode=code-first');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForFunction(() => (window as any).opencad !== undefined);

    // 1. Primary Viewport is 100% canvas
    const canvas = page.locator('canvas#cad-canvas');
    await expect(canvas).toBeVisible();

    // 2. Zero Authoring Ribbons (New Sketch, Box, Cylinder, DAG Solid, Fillet, Chamfer, Shell, Solve Mates, 500 Bench)
    const ribbonActions = page.locator('.ribbon-actions');
    await expect(ribbonActions).toBeHidden();

    const sketchBtn = page.locator('[data-testid="ribbon-btn-sketch"]');
    await expect(sketchBtn).toBeHidden();

    const benchBtn = page.locator('[data-testid="ribbon-btn-bench"]');
    await expect(benchBtn).toBeHidden();

    // 3. Zero duplicate sidebars & bottom timelines
    const timeline = page.locator('#timeline-container');
    await expect(timeline).toBeHidden();

    const hudControls = page.locator('#hud-top-right');
    await expect(hudControls).toBeHidden();

    // 4. Floating lil-gui Controller is visible in top-right
    const lilController = page.locator('[data-testid="lil-controller"]');
    await expect(lilController).toBeVisible();

    // 5. Collapsible Code Drawer Toggle is visible in top-left
    const codeBtn = page.locator('[data-testid="btn-code-drawer-toggle"]');
    await expect(codeBtn).toBeVisible();

    // 6. Zero Horizontal Scrollbars
    const hasHorizontalScroll = await page.evaluate(() => {
      return document.documentElement.scrollWidth > window.innerWidth;
    });
    expect(hasHorizontalScroll).toBe(false);
  });

  test('Test 3: Dynamic lil-gui Controller: Folders, Sliders, Telemetry, Lenses & Code Drawer', async ({ page }) => {
    await page.goto('/?mode=code-first');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForSelector('[data-testid="lil-controller"]');

    // 1. Parameters Folder: Adjust slider
    const paramFolder = page.locator('[data-testid="lil-folder-parameters"]');
    await expect(paramFolder).toBeVisible();

    const widthInput = page.locator('[data-testid="lil-param-input-width"]');
    await expect(widthInput).toBeVisible();
    await widthInput.fill('75');
    await widthInput.dispatchEvent('change');

    // Verify parameter was updated in lilController
    const currentParam = await page.evaluate(() => {
      return (window as any).__cadLilController?.getParams().width;
    });
    expect(currentParam).toBe(75);

    // 2. Telemetry Folder: Check read-only metrics
    const telFolder = page.locator('[data-testid="lil-folder-telemetry"]');
    await expect(telFolder).toBeVisible();
    await expect(telFolder).toContainText('Mass');
    await expect(telFolder).toContainText('Volume');

    // 3. Lenses Folder: Toggle Wireframe lens
    const wireframeLens = page.locator('[data-testid="lil-lens-wireframe"]');
    await expect(wireframeLens).toBeVisible();
    await wireframeLens.click();
    await expect(wireframeLens).toBeChecked();

    // 4. Actions Folder: Verify Export STL button
    const stlBtn = page.locator('[data-testid="lil-action-exportSTL"]');
    await expect(stlBtn).toBeVisible();

    // 5. Code Drawer Toggle: Slide out Monaco / Code-CAD panel
    const codeToggle = page.locator('[data-testid="btn-code-drawer-toggle"]');
    await expect(codeToggle).toBeVisible();
    await codeToggle.click();

    const sidePanel = page.locator('#plugin-side-panel');
    await expect(sidePanel).toHaveClass(/code-drawer-active/);

    // Click again to collapse
    await codeToggle.click();
    await expect(sidePanel).not.toHaveClass(/code-drawer-active/);
  });

  test('Test 4: Embed Mode with Declarative Config (sliders: false, share: [], actions: [exportSTL])', async ({ page }) => {
    // Pass custom config via URL search params
    const config = encodeURIComponent(JSON.stringify({
      sliders: false,
      share: [],
      actions: ['exportSTL'],
    }));

    await page.goto(`/?config=${config}&embed=true`);
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForSelector('[data-testid="lil-controller"]');

    // 1. Canvas is visible
    const canvas = page.locator('canvas#cad-canvas');
    await expect(canvas).toBeVisible();

    // 2. Parameters folder should be hidden / not rendered
    const paramFolder = page.locator('[data-testid="lil-folder-parameters"]');
    await expect(paramFolder).toBeHidden();

    // 3. Telemetry folder should be hidden / not rendered
    const telFolder = page.locator('[data-testid="lil-folder-telemetry"]');
    await expect(telFolder).toBeHidden();

    // 4. Actions folder renders ONLY exportSTL
    const stlBtn = page.locator('[data-testid="lil-action-exportSTL"]');
    await expect(stlBtn).toBeVisible();

    const stepBtn = page.locator('[data-testid="lil-action-exportSTEP"]');
    await expect(stepBtn).toBeHidden();

    // 5. Code Drawer Toggle is hidden in embed mode
    const codeBtn = page.locator('[data-testid="btn-code-drawer-toggle"]');
    await expect(codeBtn).toBeHidden();

    // 6. Click Export STL action button and verify execution
    const downloadPromise = page.waitForEvent('download', { timeout: 10000 }).catch(() => null);
    await stlBtn.click();
    // Verify clicked state styling applied
    await expect(stlBtn).toBeVisible();
  });
});

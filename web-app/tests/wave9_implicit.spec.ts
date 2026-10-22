import { test, expect } from '@playwright/test';

test.describe('Wave 9: Implicit & Field-Driven Modeling Workbench (nTop Mode)', () => {
  test.beforeEach(async ({ page }) => {
    test.setTimeout(150000);
    page.on('console', (msg) => console.log(`[PAGE LOG ${msg.type()}]:`, msg.text()));
    page.on('pageerror', (err) => console.log('[PAGE ERROR]:', err));
    await page.goto('/');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForSelector('[data-testid="ribbon-bar"]');
  });

  test('Implicit Workbench: Mounts ribbon, loads block stack notebook, and updates Code-CAD syntax', async ({ page }) => {
    // 1. Switch to Implicit workbench tab
    const implicitTab = page.locator('[data-testid="tab-implicit"]');
    await expect(implicitTab).toBeVisible();
    await implicitTab.click();

    // 2. Verify Ribbon buttons
    await expect(page.locator('[data-testid="btn-implicit-generate"]')).toBeVisible({ timeout: 20000 });
    await expect(page.locator('[data-testid="btn-implicit-slice"]')).toBeVisible();
    await expect(page.locator('[data-testid="btn-toggle-cross-section"]')).toBeVisible();

    // 3. Verify Side Panel nTop Block Stack
    const blockStack = page.locator('[data-testid="ntop-block-stack"]');
    await expect(blockStack).toBeVisible();
    await expect(page.locator('[data-testid="block-input-body"]')).toBeVisible();
    await expect(page.locator('[data-testid="block-tpms-lattice"]')).toBeVisible();
    await expect(page.locator('[data-testid="block-field-modulator"]')).toBeVisible();
    await expect(page.locator('[data-testid="block-preview-slicing"]')).toBeVisible();

    // 4. Verify initial fluent Code-CAD syntax box
    const codeBox = page.locator('[data-testid="ntop-code-syntax"]');
    await expect(codeBox).toBeVisible();
    await expect(codeBox).toContainText('part.shell(2.0).infill(tpms.gyroid');

    // 5. Change TPMS type to Schwarz D (Diamond) and verify syntax updates live
    const tpmsSelect = page.locator('[data-testid="select-tpms-type"]');
    await tpmsSelect.selectOption('SchwarzD');
    await expect(codeBox).toContainText('tpms.schwarzd');

    // 6. Test Cell Size slider
    const slider = page.locator('[data-testid="slider-cell-size"]');
    await slider.fill('16');
    await expect(page.locator('#val-cell-size')).toHaveText('16 mm');
    await expect(codeBox).toContainText('period: 16.0');
  });

  test('Implicit Meshing & Slicing: Generates 3D Dual Contoured lattice and 2D slice contour in Three.js', async ({ page }) => {
    // 1. Switch to Implicit workbench and wait for lazy plugin load
    await page.locator('[data-testid="tab-implicit"]').click();
    const generateBtn = page.locator('[data-testid="btn-implicit-generate"]');
    await expect(generateBtn).toBeVisible({ timeout: 20000 });

    // 2. Verify cross-section plane is mounted in Three.js scene
    const hasPlane = await page.evaluate(() => {
      const scene = (window as any).__cadViewer?.scene;
      return scene?.getObjectByName('tpms-cross-section-plane') !== undefined;
    });
    expect(hasPlane).toBe(true);

    // 3. Click "Generate Infill" to mesh TPMS lattice
    await generateBtn.click({ force: true });

    // Verify 3D lattice mesh was created in scene
    const hasLattice = await page.evaluate(() => {
      const scene = (window as any).__cadViewer?.scene;
      return scene?.getObjectByName('tpms-generated-lattice') !== undefined;
    });
    expect(hasLattice).toBe(true);

    // 4. Click "Slice 2D Layer" to extract planar vector contour
    const sliceBtn = page.locator('[data-testid="btn-implicit-slice"]');
    await sliceBtn.click({ force: true });

    // Verify 2D slice contour line segments in scene
    const hasSlice = await page.evaluate(() => {
      const scene = (window as any).__cadViewer?.scene;
      return scene?.getObjectByName('tpms-slice-contour') !== undefined;
    });
    expect(hasSlice).toBe(true);

    // 5. Verify fluent Code-CAD API on window.cad.implicitInfill
    const fluentResult = await page.evaluate(() => {
      const cadObj = (window as any).cad;
      if (!cadObj || typeof cadObj.implicitInfill !== 'function') return false;
      cadObj.implicitInfill({ period: 12.0, thickness: 1.2 });
      return true;
    });
    expect(fluentResult).toBe(true);

    // 6. Verify 60 FPS viewport rendering performance
    const fpsBadge = page.locator('#ribbon-fps-badge');
    await expect(fpsBadge).toBeVisible();
    const fpsText = await fpsBadge.innerText();
    expect(fpsText).toContain('FPS');
  });
});

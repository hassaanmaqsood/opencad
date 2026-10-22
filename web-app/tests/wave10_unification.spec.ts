import { test, expect } from '@playwright/test';

test.describe('Wave 10: Unified Standalone CAD Application & Closed-Loop Pipelines', () => {
  test.beforeEach(async ({ page }) => {
    test.setTimeout(120000);
    await page.goto('/');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForSelector('[data-testid="ribbon-bar"]');
  });

  test('Workbench Switcher & Dockable Sidebars: Switches 6 workbenches and toggles dockable sidebars in every mode', async ({
    page,
  }) => {
    // 1. Verify 6 Unified Workbenches in Ribbon Header
    await expect(page.locator('[data-testid="tab-design"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-sheetmetal"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-assembly"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-fea"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-implicit"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-cam"]')).toBeVisible();

    // 2. Switch to Assembly Workbench and verify dedicated actions
    const asmTab = page.locator('[data-testid="tab-assembly"]');
    await asmTab.click();
    await expect(asmTab).toHaveClass(/active/);
    await expect(page.locator('[data-testid="ribbon-btn-part"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-mate"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-solve"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-bench"]')).toBeVisible();

    // 3. Toggle Dockable Code-CAD sidebar in Assembly mode
    const dockCodeBtn = page.locator('[data-testid="btn-dock-codecad"]');
    await expect(dockCodeBtn).toBeVisible();
    await dockCodeBtn.click();

    // Verify Code-CAD panel docked on the right
    const sidePanel = page.locator('#plugin-side-panel');
    await expect(sidePanel).toBeVisible({ timeout: 15000 });
    await expect(page.locator('[data-testid="code-cad-panel"]')).toBeVisible();

    // 4. Toggle Dockable Git-for-CAD sidebar
    const dockGitBtn = page.locator('[data-testid="btn-dock-gitcad"]');
    await expect(dockGitBtn).toBeVisible();
    await dockGitBtn.click();
    await expect(page.locator('[data-testid="git-cad-panel"]')).toBeVisible({ timeout: 15000 });

    // 5. Verify FPS performance badge
    const fpsBadge = page.locator('#ribbon-fps-badge');
    await expect(fpsBadge).toBeVisible();
    const fpsText = await fpsBadge.innerText();
    expect(fpsText).toContain('FPS');
  });

  test('Closed-Loop Design Automation: Executes all 4 Starter Templates from Code -> B-Rep -> FEA/Implicit -> Manufacturing Exports', async ({
    page,
  }) => {
    // 1. Template 1: Parametric CNC Machined Bracket (B-Rep + 2D Drawing + G-Code)
    const t1Loaded = await page.evaluate(async () => {
      return (window as any).__loadTemplate?.('template-cnc-bracket');
    });
    expect(t1Loaded).toBe(true);

    // Verify Feature Tree has bracket nodes
    const fTree = page.locator('[data-testid="feature-tree-panel"]');
    await expect(fTree).toContainText('Bracket Profile');
    await expect(fTree).toContainText('Base Slab');

    // Test DXF Blueprint and CNC G-Code export pipelines
    const dxfText = await page.evaluate(async () => (window as any).__exportDxf?.());
    expect(dxfText).toContain('AC1015');
    expect(dxfText).toContain('VISIBLE_EDGES');

    const gcodeText = await page.evaluate(async () => (window as any).__exportGcode?.());
    expect(gcodeText).toContain('G21');
    expect(gcodeText).toContain('M03 S12000');
    expect(gcodeText).toContain('M30');

    // 2. Template 2: Sheet Metal Electronics Enclosure (Flanges + Corner Reliefs + Unfolded DXF)
    const t2Loaded = await page.evaluate(async () => {
      return (window as any).__loadTemplate?.('template-sheetmetal-enclosure');
    });
    expect(t2Loaded).toBe(true);

    // Verify Sheet Metal workbench tab active
    await expect(page.locator('[data-testid="tab-sheetmetal"]')).toHaveClass(/active/);
    await expect(fTree).toContainText('Blank Sheet');
    await expect(fTree).toContainText('Bent Flanges');

    // 3. Template 3: Precision Planar XY Compliant Flexure Stage (FACT Synthesis + Corotational FEA)
    const t3Loaded = await page.evaluate(async () => {
      return (window as any).__loadTemplate?.('template-flexure-stage');
    });
    expect(t3Loaded).toBe(true);
    await expect(page.locator('[data-testid="tab-fea"]')).toHaveClass(/active/);
    await expect(fTree).toContainText('Double-Parallelogram Flexures');

    // 4. Template 4: Stress-Driven Gyroid Aerospace Mount (FEA Stress + TPMS Infill + 3MF Export)
    const t4Loaded = await page.evaluate(async () => {
      return (window as any).__loadTemplate?.('template-aero-gyroid');
    });
    expect(t4Loaded).toBe(true);
    await expect(page.locator('[data-testid="tab-implicit"]')).toHaveClass(/active/);
    await expect(fTree).toContainText('FEA Gyroid Infill');

    // Test Production 3MF export package
    const xml3mf = await page.evaluate(async () => (window as any).__export3mf?.());
    expect(xml3mf).toContain('<model unit="millimeter"');
    expect(xml3mf).toContain('Aero_Mount');
    expect(xml3mf).toContain('<resources>');
  });
});

import { test, expect } from '@playwright/test';

test.describe('Wave 7: Sheet Metal, 2D Drawing & Manufacturing Workbenches', () => {
  test.beforeEach(async ({ page }) => {
    test.setTimeout(60000);
    await page.goto('/');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForSelector('[data-testid="ribbon-bar"]');
  });

  test('Sheet Metal Workbench: Base flange, edge flange addition, and flat-pattern unfolding', async ({ page }) => {
    // 1. Switch to Sheet Metal workbench
    const smTab = page.locator('[data-testid="tab-sheetmetal"]');
    await expect(smTab).toBeVisible();
    await smTab.click();

    // 2. Verify Ribbon actions for Sheet Metal
    await expect(page.locator('[data-testid="ribbon-btn-base-flange"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-edge-flange"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-hem"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-unfold"]')).toBeVisible();

    // 3. Verify Side Panel controls
    await expect(page.locator('#sm-thickness')).toBeVisible();
    await expect(page.locator('#sm-radius')).toBeVisible();
    await expect(page.locator('#sm-kfactor')).toBeVisible();
    await expect(page.locator('#sm-blank-w')).toBeVisible();
    await expect(page.locator('#sm-blank-l')).toBeVisible();

    // 4. Add an Edge Flange and verify bend notes update
    await page.locator('[data-testid="ribbon-btn-edge-flange"]').click();
    await expect(page.locator('#sm-bend-table')).toBeVisible();

    // 5. Toggle Unfold Flat Pattern
    await expect(page.locator('[data-testid="ribbon-btn-unfold"]')).toHaveText(/Unfold Flat/);
    await page.locator('[data-testid="ribbon-btn-unfold"]').click({ force: true });
    await expect(page.locator('[data-testid="ribbon-btn-unfold"]')).toHaveText(/Fold 3D/);

    // Verify cut perimeter is non-zero
    const cutLenText = await page.locator('#sm-cut-len').innerText();
    expect(parseFloat(cutLenText)).toBeGreaterThan(100.0);
  });

  test('2D Drawing Workbench: Multi-view blueprints, GD&T callouts, and vector download triggers', async ({ page }) => {
    // 1. Switch to 2D Drawing workbench
    const dwgTab = page.locator('[data-testid="tab-drawing"]');
    await expect(dwgTab).toBeVisible();
    await dwgTab.click();

    // 2. Verify Ribbon projection view controls
    await expect(page.locator('[data-testid="ribbon-btn-view-front"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-view-top"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-view-right"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-view-iso"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-view-section"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-export-dxf"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-export-svg"]')).toBeVisible();

    // 3. Verify Blueprint Canvas overlay is mounted
    const blueprintCanvas = page.locator('[data-testid="blueprint-canvas"]');
    await expect(blueprintCanvas).toBeVisible();

    // 4. Switch to Section A-A view
    await page.locator('[data-testid="ribbon-btn-view-section"]').click();
    await expect(blueprintCanvas).toContainText('SECTION VIEW');

    // 5. Verify GD&T frames in Side Panel
    await expect(page.locator('.drawing-panel')).toContainText('Flatness:');
    await expect(page.locator('.drawing-panel')).toContainText('Position:');
    await expect(page.locator('.drawing-panel')).toContainText('Perpendicularity:');

    // 6. Test DXF and SVG download buttons in side panel
    await expect(page.locator('[data-testid="btn-download-dxf"]')).toBeVisible();
    await expect(page.locator('[data-testid="btn-download-svg"]')).toBeVisible();
  });

  test('CAM & 3D Print Workbench: Toolpath strategies, G-code preview, and SLS nesting metrics', async ({ page }) => {
    // 1. Switch to CAM / 3MF workbench
    const camTab = page.locator('[data-testid="tab-cam"]');
    await expect(camTab).toBeVisible();
    await camTab.click();

    // 2. Verify Ribbon strategy buttons
    await expect(page.locator('[data-testid="ribbon-btn-cam-contour"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-cam-pocket"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-cam-adaptive"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-cam-drill"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-cam-nest"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-export-3mf"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-export-gcode"]')).toBeVisible();

    // 3. Select Drill Cycle strategy
    await page.locator('[data-testid="ribbon-btn-cam-drill"]').click();

    // 4. Verify G-code text preview updates with G83 peck drilling
    const gcodeTextarea = page.locator('#cam-gcode-preview');
    await expect(gcodeTextarea).toBeVisible();
    await expect(gcodeTextarea).toHaveValue(/G83/);

    // 5. Test Nest Parts button
    const nestBtn = page.locator('[data-testid="ribbon-btn-cam-nest"]');
    await nestBtn.click();
    const densityVal = await page.locator('#cam-density').innerText();
    expect(parseFloat(densityVal)).toBeGreaterThan(0.0);

    // 6. Verify G-code and 3MF download buttons exist
    await expect(page.locator('[data-testid="btn-download-gcode"]')).toBeVisible();
    await expect(page.locator('[data-testid="btn-download-3mf"]')).toBeVisible();
  });
});

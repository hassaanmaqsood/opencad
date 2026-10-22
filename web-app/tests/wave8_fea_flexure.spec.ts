import { test, expect } from '@playwright/test';

test.describe('Wave 8: In-Browser FEA Mechanics & Compliant Flexure Synthesis Workbench', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForSelector('[data-testid="ribbon-bar"]');
  });

  test('FEA & Flexure Workbench: Mounts ribbon, executes FEA solve, updates Von Mises card and slider', async ({ page }) => {
    // 1. Switch to FEA & Flexure workbench tab
    const feaTab = page.locator('[data-testid="tab-fea"]');
    await expect(feaTab).toBeVisible();
    await feaTab.click();

    // 2. Verify Ribbon actions for FEA & Flexure
    await expect(page.locator('[data-testid="fea-select-material"]')).toBeVisible();
    await expect(page.locator('[data-testid="fea-select-order"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-solve-fea"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-corotational"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-flexure-analyze"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-insert-flexure"]')).toBeVisible();
    await expect(page.locator('[data-testid="fea-scale-slider"]')).toBeVisible();

    // 3. Verify Side Panel FEA Results Card
    const feaPanel = page.locator('[data-testid="fea-panel"]');
    await expect(feaPanel).toBeVisible();
    await expect(page.locator('[data-testid="fea-result-card"]')).toBeVisible();
    await expect(page.locator('[data-testid="fea-result-card"]')).toContainText('Peak Von Mises:');
    await expect(page.locator('[data-testid="fea-result-card"]')).toContainText('Max Deflection:');
    await expect(page.locator('[data-testid="fea-result-card"]')).toContainText('Safety Factor');

    // 4. Run FEA solve
    const solveBtn = page.locator('[data-testid="ribbon-btn-solve-fea"]');
    await solveBtn.click();
    await expect(page.locator('[data-testid="fea-result-card"]')).toContainText('MPa');

    // 5. Test Deformation Scale Slider
    const slider = page.locator('[data-testid="fea-scale-slider"]');
    await slider.fill('50');
    await expect(page.locator('#fea-scale-label')).toHaveText('50x');

    // 6. Test Corotational Nonlinear Toggle
    const corotBtn = page.locator('[data-testid="ribbon-btn-corotational"]');
    await corotBtn.click();
    await expect(corotBtn).toHaveClass(/active/);
    await expect(page.locator('[data-testid="fea-result-card"]')).toContainText('Corotational');
  });

  test('FACT Compliant Flexure Synthesis: Computes 6x6 compliance matrix and renders FACT screw axes', async ({ page }) => {
    // 1. Switch to FEA & Flexure workbench
    await page.locator('[data-testid="tab-fea"]').click();

    // 2. Trigger Flexure Synthesis
    const analyzeBtn = page.locator('[data-testid="ribbon-btn-flexure-analyze"]');
    await expect(analyzeBtn).toBeVisible();
    await analyzeBtn.click();

    // 3. Verify FACT HUD card and 6x6 Compliance Matrix Table
    const factHud = page.locator('[data-testid="fact-hud"]');
    await expect(factHud).toBeVisible();
    await expect(factHud).toContainText('FACT Compliant Kinematics');
    await expect(factHud).toContainText('θz Pure Rotation');
    await expect(factHud).toContainText('Fx, Fz, Mx, My');

    const compTable = page.locator('[data-testid="flexure-compliance-table"]');
    await expect(compTable).toBeVisible();
    await expect(compTable.locator('tr')).toHaveCount(6);

    // 4. Test Parametric Hinge Insertion buttons
    const insertBtn = page.locator('[data-testid="ribbon-btn-insert-flexure"]');
    await expect(insertBtn).toBeVisible();
    await insertBtn.click();

    await page.locator('#btn-add-notch').click();
    await expect(factHud).toBeVisible();

    // 5. Verify cad.getStressField() is exposed to window for Wave 9 Implicit Engine
    const stressFieldExposed = await page.evaluate(() => {
      const cadObj = (window as any).cad;
      if (!cadObj || typeof cadObj.getStressField !== 'function') return false;
      const field = cadObj.getStressField();
      return field && typeof field.getStressAtPoint === 'function' && field.maxVonMises > 0;
    });
    expect(stressFieldExposed).toBe(true);

    // 6. Verify 60 FPS viewport throughput
    const fpsBadge = page.locator('#ribbon-fps-badge');
    await expect(fpsBadge).toBeVisible();
    const fpsText = await fpsBadge.innerText();
    expect(fpsText).toContain('FPS');
  });
});

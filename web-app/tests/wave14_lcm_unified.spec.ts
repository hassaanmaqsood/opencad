import { test, expect } from '@playwright/test';

test.describe('Wave 14: The LCM Unified Interface Suite', () => {
  test.beforeEach(async ({ page }) => {
    test.setTimeout(120000);
    await page.goto('/');
    await page.waitForSelector('canvas#cad-canvas');
    await page.waitForFunction(() => (window as any).opencad !== undefined);
  });

  test('Test 1: Universal Omni-Bar accepts tool search, math formula assignments, slash commands & AI prompts', async ({ page }) => {
    const omniBar = page.locator('[data-testid="omni-bar"]');
    await expect(omniBar).toBeVisible();

    const omniInput = page.locator('[data-testid="omni-bar-input"]');
    await expect(omniInput).toBeVisible();

    // 1. Focus using shortcut Ctrl+K
    await page.keyboard.press('Control+k');
    await expect(omniInput).toBeFocused();

    // Dropdown should be visible
    const dropdown = page.locator('[data-testid="omni-dropdown"]');
    await expect(dropdown).toBeVisible();

    // 2. Search for tool 'fillet'
    await omniInput.fill('fillet');
    const filletItem = page.locator('[data-testid="omni-item-fillet"]');
    await expect(filletItem).toBeVisible();
    await filletItem.click();

    // Telemetry bar should echo operation
    const telemetry = page.locator('[data-testid="telemetry-bar"]');
    await expect(telemetry).toBeVisible();
    const telemetryCode = page.locator('[data-testid="telemetry-code"]');
    await expect(telemetryCode).toContainText('fillet');

    // 3. Mathematical parameter assignment (e.g. width = 3.5)
    await page.keyboard.press('Control+k');
    await omniInput.fill('width = 3.5');
    await page.keyboard.press('Enter');

    await expect(telemetryCode).toContainText('parameters.set("width", 3.5)');
    const widthSlider = page.locator('[data-testid="param-slider-width"]');
    await expect(widthSlider).toHaveValue('3.5');

    // 4. Slash command (/export step)
    await page.keyboard.press('Control+k');
    await omniInput.fill('/export step');
    const stepItem = page.locator('[data-testid="omni-item-slash_step"]');
    await expect(stepItem).toBeVisible();
    await stepItem.click();

    await expect(telemetryCode).toContainText('export_step');

    // 5. Dismiss dropdown with Escape
    await page.keyboard.press('Control+k');
    await expect(dropdown).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(dropdown).toBeHidden();
  });

  test('Test 2: Living Recipe Dock merges Parameter Sliders + Feature DAG Tree with Inline Scrubbable Badges & Code Toggle', async ({ page }) => {
    const dock = page.locator('[data-testid="living-recipe-dock"]');
    await expect(dock).toBeVisible();

    // 1. Parameter Sliders with scrubbable range slider + formula/number box
    const slidersSection = page.locator('[data-testid="recipe-parameter-sliders"]');
    await expect(slidersSection).toBeVisible();

    const widthInput = page.locator('[data-testid="param-input-width"]');
    await expect(widthInput).toBeVisible();
    await widthInput.fill('4.2');
    await widthInput.dispatchEvent('change');

    const widthSlider = page.locator('[data-testid="param-slider-width"]');
    await expect(widthSlider).toHaveValue('4.2');

    // 2. Feature & Assembly DAG Tree with inline scrubbable badges
    const featureTree = page.locator('[data-testid="feature-tree-panel"]');
    await expect(featureTree).toBeVisible();

    const scrubBadge = page.locator('[data-testid^="scrub-badge-"]').first();
    await expect(scrubBadge).toBeVisible();
    const badgeText = await scrubBadge.innerText();
    expect(badgeText).toContain('mm');

    // Click scrub badge to reveal inline editable input
    await scrubBadge.click();
    const inlineInput = page.locator('.inline-scrub-input');
    await expect(inlineInput).toBeVisible();
    await inlineInput.fill('25.0');
    await inlineInput.press('Enter');

    // 3. Header toggle for { } Code-CAD editor
    const codeBtn = page.locator('[data-testid="recipe-btn-code"]');
    await expect(codeBtn).toBeVisible();
    await codeBtn.click();

    const sidePanel = page.locator('#plugin-side-panel');
    await expect(sidePanel).toBeVisible({ timeout: 15000 });
  });

  test('Test 3: Center 3D Viewport displays On-Object Contextual HUD, Semantic Selector Badge (>Z) & Push/Pull Arrow', async ({ page }) => {
    // 1. Select face programmatically via window.opencad.select('>Z')
    await page.evaluate(() => {
      (window as any).opencad.select('>Z');
    });

    const hud = page.locator('[data-testid="on-object-hud"]');
    await expect(hud).toBeVisible();

    // 2. Check Semantic Selector Badge
    const badge = page.locator('[data-testid="semantic-selector-badge"]');
    await expect(badge).toBeVisible();
    await expect(badge).toHaveText('>Z');

    // 3. Dimension input box
    const dimInput = page.locator('[data-testid="hud-dimension-input"]');
    await expect(dimInput).toBeVisible();
    await dimInput.fill('30.00');
    await dimInput.dispatchEvent('change');

    const telemetryCode = page.locator('[data-testid="telemetry-code"]');
    await expect(telemetryCode).toContainText('30');

    // 4. Quick Action buttons
    const extrudeAction = page.locator('[data-testid="hud-action-extrude"]');
    await expect(extrudeAction).toBeVisible();
    await extrudeAction.click();

    await expect(telemetryCode).toContainText('extrude');
    await expect(hud).toBeHidden();
  });

  test('Test 4: Bottom Lenses & Kinematic Timeline Scrubber toggle Section A-A, FEA, Sheet Metal, CAM & Motion', async ({ page }) => {
    const lensesBar = page.locator('[data-testid="bottom-lenses-bar"]');
    await expect(lensesBar).toBeVisible();

    const telemetryCode = page.locator('[data-testid="telemetry-code"]');

    // 1. Toggle Section A-A Lens
    const sectionBtn = page.locator('[data-testid="lens-section"]');
    await expect(sectionBtn).toBeVisible();
    await sectionBtn.click();
    await expect(sectionBtn).toHaveClass(/active/);
    await expect(telemetryCode).toContainText('view.setLens("section", true)');

    // 2. Toggle FEA & Flexure Lens
    const feaBtn = page.locator('[data-testid="lens-fea"]');
    await expect(feaBtn).toBeVisible();
    await feaBtn.click();
    await expect(feaBtn).toHaveClass(/active/);
    await expect(telemetryCode).toContainText('view.setLens("fea", true)');

    // 3. Toggle Sheet Metal Unfold Lens
    const smBtn = page.locator('[data-testid="lens-sheetmetal"]');
    await expect(smBtn).toBeVisible();
    await smBtn.click();
    await expect(smBtn).toHaveClass(/active/);
    await expect(telemetryCode).toContainText('view.setLens("sheetmetal", true)');

    // 4. Explode Scrubber
    const explodeScrubber = page.locator('[data-testid="assembly-explode-scrubber"]');
    await expect(explodeScrubber).toBeVisible();
    await explodeScrubber.fill('40');
    await explodeScrubber.dispatchEvent('input');
    await expect(telemetryCode).toContainText('assembly.setExplodeFactor(0.40)');

    // 5. Motion Scrubber & Play button
    const motionScrubber = page.locator('[data-testid="assembly-motion-scrubber"]');
    await expect(motionScrubber).toBeVisible();
    await motionScrubber.fill('180');
    await motionScrubber.dispatchEvent('input');
    await expect(telemetryCode).toContainText('assembly.setKinematicAngle(180.0)');
    await expect(page.locator('#motion-angle-readout')).toHaveText('180°');

    const playBtn = page.locator('[data-testid="btn-motion-play"]');
    await expect(playBtn).toBeVisible();
    await playBtn.click();
    await expect(playBtn).toHaveClass(/playing/);
    await playBtn.click();
    await expect(playBtn).not.toHaveClass(/playing/);
  });

  test('Test 5: Always-On window.opencad Global & Headless Agent API: runCommand, select, getRecipeAST, getDiagnostics & Orthographic Captures', async ({ page }) => {
    const apiResult = await page.evaluate(async () => {
      const ocad = (window as any).opencad;
      if (!ocad) return { error: 'window.opencad not found' };

      // 1. runCommand: createBox
      const boxRes = await ocad.runCommand('createBox', { dimensions: [3.5, 3.5, 3.5] });

      // 2. select semantic selector
      const sel = ocad.select('>Z');

      // 3. getDiagnostics
      const diag = await ocad.getDiagnostics();

      // 4. getRecipeAST
      const ast = ocad.getRecipeAST();

      // 5. captureOrthographicViews
      const views = await ocad.captureOrthographicViews();

      // 6. setParameter
      ocad.setParameter('width', 5.0);

      // 7. exportStep
      const step = await ocad.exportStep();

      return {
        boxRes,
        selType: sel.type,
        diag,
        astLength: ast.length,
        hasViews: !!(views.isometric && views.top && views.front),
        hasStep: typeof step === 'string' && step.includes('ISO-10303-21'),
      };
    });

    expect(apiResult.boxRes.success).toBe(true);
    expect(apiResult.selType).toBe('face');
    expect(apiResult.diag.watertight).toBe(true);
    expect(apiResult.diag.euler).toBe(2);
    expect(apiResult.diag.fps).toBeGreaterThan(0);
    expect(apiResult.astLength).toBeGreaterThanOrEqual(1);
    expect(apiResult.hasViews).toBe(true);
    expect(apiResult.hasStep).toBe(true);
  });
});

import { test, expect } from '@playwright/test';

test.describe('Wave 13: Persona-Adaptive UI, Sketch HUD & WebMCP Suite', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.waitForSelector('#cad-canvas', { state: 'visible' });
    await page.waitForFunction(() => window.__cadViewer !== undefined);
  });

  test('Test 1: 4-Persona Switcher adapts the viewport UI between Engineer, Maker, Developer, and AI-Agent', async ({ page }) => {
    const personaSelect = page.locator('[data-testid="persona-selector"]');
    await expect(personaSelect).toBeVisible();

    // 1. Switch to Maker Mode
    await personaSelect.selectOption('maker');
    const isMakerBody = await page.evaluate(() => document.body.classList.contains('persona-maker'));
    expect(isMakerBody).toBe(true);

    // Maker 1-click download buttons must be present
    const mStep = page.locator('[data-testid="btn-maker-export-step"]');
    await expect(mStep).toBeVisible();

    // 2. Switch to AI-Agent Mode
    await personaSelect.selectOption('ai-agent');
    const isAgentBody = await page.evaluate(() => document.body.classList.contains('persona-ai-agent'));
    expect(isAgentBody).toBe(true);

    const agentHud = page.locator('[data-testid="agent-hud"]');
    await expect(agentHud).toBeVisible();
    const statusBadge = page.locator('[data-testid="agent-status-badge"]');
    await expect(statusBadge).toHaveText('READY');

    // 3. Switch back to Engineer Mode
    await personaSelect.selectOption('engineer');
    const isEngineerBody = await page.evaluate(() => document.body.classList.contains('persona-engineer'));
    expect(isEngineerBody).toBe(true);

    const dPlaneBtn = page.locator('[data-testid="btn-datum-plane"]');
    await expect(dPlaneBtn).toBeVisible();
    const scrubber = page.locator('[data-testid="assembly-motion-scrubber"]');
    await expect(scrubber).toBeVisible();
  });

  test('Test 2: S-Key Radial Pie Menu opens on hotkey and triggers CAD tools', async ({ page }) => {
    // Click canvas to ensure focus and press 's'
    await page.click('#cad-canvas');
    await page.keyboard.press('s');

    const radialMenu = page.locator('[data-testid="radial-pie-menu"]');
    await expect(radialMenu).toBeVisible();

    // Check radial items
    const radialFillet = page.locator('[data-testid="radial-fillet"]');
    await expect(radialFillet).toBeVisible();

    // Press Escape to dismiss
    await page.keyboard.press('Escape');
    await expect(radialMenu).toBeHidden();
  });

  test('Test 3: AI-Agent WebMCP JSON-RPC API executes commands, captures multi-angle snapshots, and validates B-Rep', async ({ page }) => {
    const agentResult = await page.evaluate(async () => {
      const agent = (window as any).opencadAgent;
      if (!agent) return { error: 'No opencadAgent found' };

      // 1. Execute command: createBox
      const cmdRes = await agent.executeCommand('createBox', { dimensions: [3, 3, 3] });

      // 2. Capture viewport snapshots
      const snapshots = await agent.captureViewport(['current', 'isometric']);

      // 3. Validate B-Rep invariants
      const bRepVal = await agent.validateBRep();

      // 4. Tools list
      const tools = agent.getAvailableTools();

      return {
        cmdRes,
        hasSnapshots: Object.keys(snapshots).length === 2 && snapshots.isometric.startsWith('data:image/png'),
        bRepVal,
        toolCount: tools.length,
      };
    });

    expect(agentResult.cmdRes.success).toBe(true);
    expect(agentResult.hasSnapshots).toBe(true);
    expect(agentResult.bRepVal.isValid).toBe(true);
    expect(agentResult.bRepVal.eulerCharacteristic).toBe(2);
    expect(agentResult.toolCount).toBeGreaterThanOrEqual(8);
  });

  test('Test 4: Interactive Sketch HUD exposes Spline, Slot, Text, 2D Modifiers and Construction Q Toggle', async ({ page }) => {
    // Enter sketch mode
    const sketchBtn = page.locator('[data-testid="ribbon-btn-sketch"]');
    await sketchBtn.click();

    const sketchHud = page.locator('#sketch-hud-root');
    await expect(sketchHud).toBeVisible();

    // Advanced tools
    await expect(page.locator('[data-testid="tool-spline"]')).toBeVisible();
    await expect(page.locator('[data-testid="tool-slot"]')).toBeVisible();
    await expect(page.locator('[data-testid="tool-text"]')).toBeVisible();
    await expect(page.locator('[data-testid="tool-fillet-2d"]')).toBeVisible();
    await expect(page.locator('[data-testid="tool-chamfer-2d"]')).toBeVisible();
    await expect(page.locator('[data-testid="tool-offset"]')).toBeVisible();
    await expect(page.locator('[data-testid="tool-trim"]')).toBeVisible();

    // Test Construction toggle with 'Q' key
    const constBtn = page.locator('[data-testid="btn-toggle-construction"]');
    await expect(constBtn).toBeVisible();

    // Toggle by pressing 'q'
    await page.keyboard.press('q');
    await expect(constBtn).toHaveClass(/active/);

    await page.keyboard.press('q');
    await expect(constBtn).not.toHaveClass(/active/);

    // Finish sketch
    await page.locator('[data-testid="btn-exit-sketch"]').click();
  });
});

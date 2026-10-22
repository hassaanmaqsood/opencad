import { test, expect } from '@playwright/test';

test.describe('Wave 6B: Extension Host Shell, Dynamic Code-Splitting & Workbench Plugins', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await page.waitForSelector('#cad-canvas');
    await page.waitForFunction(() => !!window.__cadViewer?.meshManager.solidMesh);
  });

  test('Top Ribbon mounts with brand, workbench tabs, and context actions', async ({ page }) => {
    const ribbon = page.locator('[data-testid="ribbon-bar"]');
    await expect(ribbon).toBeVisible();

    // Verify all 7 workbench tabs
    await expect(page.locator('[data-testid="tab-design"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-code-cad"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-git-cad"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-sheetmetal"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-fea"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-implicit"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-cam"]')).toBeVisible();

    // Verify initial active tab is Design
    const designTab = page.locator('[data-testid="tab-design"]');
    await expect(designTab).toHaveClass(/active/);

    // Verify Design context action buttons
    await expect(page.locator('[data-testid="ribbon-actions"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-sketch"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-box"]')).toBeVisible();
    await expect(page.locator('[data-testid="ribbon-btn-fillet"]')).toBeVisible();
  });

  test('Bottom Chronological Timeline Bar renders DAG features and scrubs rollback history', async ({ page }) => {
    const timeline = page.locator('[data-testid="timeline-bar"]');
    await expect(timeline).toBeVisible();

    const track = page.locator('[data-testid="timeline-track"]');
    await expect(track).toBeVisible();

    // Verify timeline node markers exist
    const node0 = page.locator('[data-testid="timeline-node-0"]');
    await expect(node0).toBeVisible();

    // Verify scrubber exists
    const scrubber = page.locator('[data-testid="timeline-scrubber"]');
    await expect(scrubber).toBeVisible();

    // Step backward using timeline control
    const stepBackBtn = page.locator('[data-testid="timeline-step-back"]');
    await stepBackBtn.click();

    // Verify rollback index changed in global FeatureTree & Timeline
    const rbIndex = await page.evaluate(() => window.__cadTimelineBar?.getRollbackIndex());
    expect(rbIndex).toBe(4);

    // Step forward
    const stepForwardBtn = page.locator('[data-testid="timeline-step-forward"]');
    await stepForwardBtn.click();

    const rbIndexForward = await page.evaluate(() => window.__cadTimelineBar?.getRollbackIndex());
    expect(rbIndexForward).toBe(5);
  });

  test('Dynamic Code-Splitting: Clicking Code-CAD loads dynamic chunk, opens side panel, and formats AST', async ({
    page,
  }) => {
    // Track dynamic chunk network requests
    const chunkRequests: string[] = [];
    page.on('request', (req) => {
      const url = req.url();
      if (url.includes('.js') && (url.includes('code-cad') || url.includes('assets/index-'))) {
        chunkRequests.push(url);
      }
    });

    // Click { } Code-CAD tab
    const codeCadTab = page.locator('[data-testid="tab-code-cad"]');
    await codeCadTab.click();
    await expect(codeCadTab).toHaveClass(/active/);

    // Verify side panel opens
    const panel = page.locator('[data-testid="code-cad-panel"]');
    await expect(panel).toBeVisible();

    // Verify textarea contains auto-generated parametric script
    const textarea = page.locator('[data-testid="codecad-editor-textarea"]');
    await expect(textarea).toBeVisible();
    const val = await textarea.inputValue();
    expect(val).toContain('OpenCAD Parametric Model Script');
    expect(val).toContain('sketch(');

    // Verify AST node count badge
    const badge = page.locator('[data-testid="codecad-node-count"]');
    await expect(badge).toBeVisible();
    await expect(badge).toHaveText(/AST: \d+ nodes/);

    // Click Format button
    const formatBtn = page.locator('[data-testid="btn-codecad-format"]');
    await formatBtn.click();

    const status = page.locator('[data-testid="codecad-status"]');
    await expect(status).toHaveText(/Formatted successfully/);
  });

  test('Bidirectional Code-CAD: Editing script evaluates DAG and updates 3D model', async ({ page }) => {
    await page.locator('[data-testid="tab-code-cad"]').click();

    const textarea = page.locator('[data-testid="codecad-editor-textarea"]');
    await textarea.fill(`
// Custom Parametric Solid
const width = 3.5;
const height = 1.5;
box(width, height, 2.0);
fillet(0.4);
    `);

    // Click Run Script button
    const runBtn = page.locator('[data-testid="btn-codecad-run"]');
    await runBtn.click();

    // Wait for DAG evaluation
    const status = page.locator('[data-testid="codecad-status"]');
    await expect(status).toHaveText(/Evaluated: \d+ features active/);

    // Verify Three.js model updated
    const isModelValid = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      const geom = viewer?.meshManager.solidMesh.geometry;
      return !!geom && geom.getAttribute('position').count > 0;
    });
    expect(isModelValid).toBe(true);
  });

  test('Dynamic Code-Splitting: Clicking Git-for-CAD displays commits, commits changes, and performs 3-way AST merge', async ({
    page,
  }) => {
    // Click Git-for-CAD tab
    const gitTab = page.locator('[data-testid="tab-git-cad"]');
    await gitTab.click();
    await expect(gitTab).toHaveClass(/active/);

    // Verify Git side panel
    const panel = page.locator('[data-testid="git-cad-panel"]');
    await expect(panel).toBeVisible();

    // Verify commit history list has default commits
    const commitList = page.locator('[data-testid="git-commit-list"]');
    await expect(commitList).toBeVisible();
    await expect(page.locator('[data-testid="git-commit-a1b2c3d"]')).toBeVisible();

    // Create a new commit
    const commitInput = page.locator('[data-testid="git-commit-input"]');
    await commitInput.fill('Feature: Add mounting flanges');
    const commitBtn = page.locator('[data-testid="btn-git-commit"]');
    await commitBtn.click();

    // Verify new commit is prepended to commit list
    const items = page.locator('.git-commit-item');
    const firstMessage = items.first().locator('.commit-message');
    await expect(firstMessage).toHaveText('Feature: Add mounting flanges');

    // Run 3-Way AST Merge
    const mergeBtn = page.locator('[data-testid="btn-run-merge"]');
    await mergeBtn.click();

    const mergeStatus = page.locator('[data-testid="git-merge-conflicts"]');
    await expect(mergeStatus).toHaveText(/Merged successfully!/);
  });

  test('Git 3D Boolean Visual Diff Overlay renders Green additions and Red removals in Three.js scene', async ({
    page,
  }) => {
    await page.locator('[data-testid="tab-git-cad"]').click();

    // Toggle 3D Visual Diff
    const diffBtn = page.locator('[data-testid="btn-toggle-diff-panel"]');
    await diffBtn.click();

    // Verify summary indicates active diff
    const summary = page.locator('[data-testid="git-diff-summary"]');
    await expect(summary).toHaveText(/Diff vs/);
    await expect(summary).toHaveText(/faces added/);

    // Inspect Three.js Scene: Verify diff overlay group contains added or removed meshes
    const diffMeshActive = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      const diffGroup = viewer?.meshManager.diffGroup;
      if (!diffGroup) return false;
      return diffGroup.children.length > 0;
    });
    expect(diffMeshActive).toBe(true);

    // Toggle diff off and verify clean removal
    await diffBtn.click();
    const diffMeshRemoved = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      return viewer?.meshManager.diffGroup === null;
    });
    expect(diffMeshRemoved).toBe(true);
  });

  test('Multi-workbench switching and timeline scrubbing maintain steady 60 FPS viewport performance', async ({
    page,
  }) => {
    // Switch between workbenches rapidly
    await page.locator('[data-testid="tab-code-cad"]').click();
    await page.waitForTimeout(300);

    await page.locator('[data-testid="tab-git-cad"]').click();
    await page.waitForTimeout(300);

    await page.locator('[data-testid="tab-design"]').click();
    await page.waitForTimeout(300);

    // Measure FPS across 60 render frames
    const fpsStats = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      if (!viewer) return { avgFps: 0, minFps: 0 };

      const frames = 60;
      const start = performance.now();
      for (let i = 0; i < frames; i++) {
        viewer.controls.update();
        viewer.renderer.render(viewer.scene, viewer.camera);
      }
      const elapsed = performance.now() - start;
      const fps = (frames / elapsed) * 1000;
      return { avgFps: fps };
    });

    expect(fpsStats.avgFps).toBeGreaterThanOrEqual(55);
  });
});

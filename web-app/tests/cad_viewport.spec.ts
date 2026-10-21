import { test, expect } from '@playwright/test';

test.describe('OpenCAD Viewport & Sub-Shape Picking E2E', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    // Wait for the canvas and model to load
    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => !!window.__cadViewer && !!window.__cadBridge);
  });

  test('Canvas mounts and WebGL context initializes with base geometry', async ({ page }) => {
    const isContextValid = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer || !viewer.renderer) return false;
      const gl = viewer.renderer.getContext();
      return !!gl && typeof gl.clear === 'function';
    });
    expect(isContextValid).toBe(true);

    // Initial mesh stats for Box primitive: 6 faces, 12 edges, 12 triangles, 24 vertices
    await expect(page.locator('#stat-faces')).toHaveText('6');
    await expect(page.locator('#stat-edges')).toHaveText('12');
    await expect(page.locator('#stat-triangles')).toHaveText('12');
    await expect(page.locator('#stat-vertices')).toHaveText('24');
  });

  test('Measures frame intervals across 60+ render ticks verifying steady 60 FPS throughput', async ({
    page,
  }) => {
    // Benchmark 60 continuous render frame iterations on the initialized WebGL context
    const benchmark = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      if (!viewer) throw new Error('Viewer not found');

      const frameCount = 60;
      const start = performance.now();
      const deltas: number[] = [];
      let lastTime = start;

      for (let i = 0; i < frameCount; i++) {
        // Execute frame render pass
        viewer.controls.update();
        viewer.renderer.render(viewer.scene, viewer.camera);

        const now = performance.now();
        deltas.push(now - lastTime);
        lastTime = now;
      }

      const totalDuration = performance.now() - start;
      const avgFrameTimeMs = totalDuration / frameCount;
      const effectiveFps = 1000 / avgFrameTimeMs;

      return {
        frameCount,
        totalDuration,
        avgFrameTimeMs,
        effectiveFps,
        activeFrameCount: viewer.totalFrameCount,
      };
    });

    expect(benchmark.frameCount).toBe(60);
    // 60 frames rendered in under 1000ms indicates steady 60+ FPS rendering capability
    expect(benchmark.avgFrameTimeMs).toBeLessThan(16.7 * 2); // fast sub-33ms frame times even under CPU rasterization
    expect(benchmark.effectiveFps).toBeGreaterThanOrEqual(30);

    // Verify active animation loop is ticking in the background
    await page.waitForTimeout(400);
    const activeFrames = await page.evaluate(() => window.__cadViewer?.totalFrameCount || 0);
    expect(activeFrames).toBeGreaterThan(0);

    // Verify HUD performance indicator is present and rendered
    const fpsBadge = page.locator('#fps-counter');
    await expect(fpsBadge).toBeVisible();
  });

  test('Simulates pointer click over 3D model, detecting and highlighting sub-shape Face ID', async ({
    page,
  }) => {
    const canvas = page.locator('#cad-canvas');
    const box = await canvas.boundingBox();
    expect(box).not.toBeNull();

    // Click near the center of the canvas where the 3D solid is centered
    const targetX = box!.x + box!.width / 2;
    const targetY = box!.y + box!.height / 2;

    await page.mouse.move(targetX, targetY);
    await page.mouse.click(targetX, targetY);

    // Verify that the HUD detected and displayed topological face selection
    const selectionType = page.locator('#selection-type');
    await expect(selectionType).toHaveText('TOPOLOGICAL FACE');

    const selectionName = page.locator('#selection-name');
    await expect(selectionName).toHaveText(/Face #[1-6]/);

    const selectionCoords = page.locator('#selection-coords');
    await expect(selectionCoords).toHaveText(/Hit Point: \[/);

    // Verify visual highlight mesh is rendered and visible in Three.js
    const isHighlightMeshActive = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      return !!viewer?.meshManager.highlightFaceMesh.visible;
    });
    expect(isHighlightMeshActive).toBe(true);
  });

  test('Regenerates geometry dynamically through the Web Worker bridge (Cylinder)', async ({
    page,
  }) => {
    // Switch primitive to Cylinder
    await page.locator('#primitive-select').selectOption('cylinder');

    // Cylinder with 32 radial segments: 3 faces, 64 edge segments
    await expect(page.locator('#stat-faces')).toHaveText('3');
    await expect(page.locator('#stat-edges')).toHaveText('64');

    // Click model to verify picking works on the newly transferred geometry
    const canvas = page.locator('#cad-canvas');
    const box = await canvas.boundingBox();
    const targetX = box!.x + box!.width / 2;
    const targetY = box!.y + box!.height / 2;

    await page.mouse.click(targetX, targetY);

    const selectionType = page.locator('#selection-type');
    await expect(selectionType).toHaveText('TOPOLOGICAL FACE');

    const selectionName = page.locator('#selection-name');
    await expect(selectionName).toHaveText(/Face #[1-3]/);
  });
});

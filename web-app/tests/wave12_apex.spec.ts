import { test, expect } from '@playwright/test';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

test.describe('Wave 12: Apex CAD Upgrade E2E Suite', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.waitForSelector('#cad-canvas', { state: 'visible' });
    await page.waitForFunction(() => window.__cadViewer !== undefined);
  });

  test('Test 1: Surface inspection shader mode switches between Standard, Zebra stripes, and Draft angle', async ({ page }) => {
    // 1. Verify CadViewer exists and inspection mode can be set to zebra
    const isZebra = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return false;
      viewer.setInspectionMode('zebra');
      const mat = (viewer.meshManager.solidMesh.material as any);
      return mat && mat.type === 'ShaderMaterial';
    });
    expect(isZebra).toBe(true);

    // 2. Set to draft angle inspection mode
    const isDraft = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return false;
      viewer.setInspectionMode('draft');
      const mat = (viewer.meshManager.solidMesh.material as any);
      return mat && mat.type === 'ShaderMaterial';
    });
    expect(isDraft).toBe(true);

    // 3. Reset back to standard CAD material
    const isStandard = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return false;
      viewer.setInspectionMode('standard');
      const mat = (viewer.meshManager.solidMesh.material as any);
      return mat && mat.type === 'MeshStandardMaterial';
    });
    expect(isStandard).toBe(true);
  });

  test('Test 2: Click-to-Semantic-Selector in Code-CAD mode inserts selector tag into active script', async ({ page }) => {
    // 1. Open Code-CAD sidebar using dock button
    const codeBtn = page.locator('[data-testid="btn-dock-codecad"]');
    await expect(codeBtn).toBeVisible();
    await codeBtn.click();

    const sidePanel = page.locator('#plugin-side-panel');
    await expect(sidePanel).toBeVisible({ timeout: 10000 });
    const textarea = page.locator('[data-testid="codecad-editor-textarea"]');
    await expect(textarea).toBeVisible({ timeout: 10000 });

    // 2. Trigger sub-shape face selection via CadViewer
    await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (viewer) {
        viewer.setSelection({
          type: 'face',
          faceId: 0,
          topoId: 0x101n,
          point: [0, 0, 10],
        });
      }
    });

    // 3. Verify textarea in Code-CAD contains inserted selector
    const content = await textarea.inputValue();
    expect(content).toContain('.select(">Z');
  });

  test('Test 3: Direct-mount <opencad-viewer> dispatches live opencad:metrics CustomEvent', async ({ page }) => {
    // Inject the bundled Web Component into page
    const bundlePath = path.resolve(__dirname, '../../dist-publish/opencad-element.mjs');
    await page.addScriptTag({ path: bundlePath, type: 'module' });

    // Inject and test <opencad-viewer mount="direct">
    const metricsReceived = await page.evaluate(async () => {
      return new Promise<any>((resolve) => {
        const checkAndMount = () => {
          if (customElements.get('opencad-viewer')) {
            const viewerEl = document.createElement('opencad-viewer') as any;
            viewerEl.setAttribute('mount', 'direct');
            viewerEl.setAttribute('template', 'bracket');
            viewerEl.addEventListener('opencad:metrics', (e: any) => {
              resolve(e.detail);
            });
            document.body.appendChild(viewerEl);
          } else {
            setTimeout(checkAndMount, 20);
          }
        };
        checkAndMount();
      });
    });

    expect(metricsReceived).toBeDefined();
    expect(metricsReceived.volumeMm3).toBe(80000.0);
    expect(metricsReceived.massGrams).toBe(216.0);
    expect(metricsReceived.bbox.dx).toBe(80.0);
  });
});

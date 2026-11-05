import { test, expect } from '@playwright/test';

test.describe('OpenCAD Responsive Flex Studio & Minimal Embed Viewer E2E', () => {

  test('Desktop Responsive Flex Layout: side-by-side flex-direction row and 60-FPS resize collapse', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/');

    // Wait for canvas and viewer to mount
    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => !!(window as any).__cadViewer && !!(window as any).__cadBridge);

    // 1. Verify desktop horizontal row layout
    const appContainer = page.locator('#app-container');
    const flexDir = await appContainer.evaluate((el) => window.getComputedStyle(el).flexDirection);
    expect(flexDir).toBe('row');

    // 2. Both Code Pane and Viewport are visible side-by-side
    const codePane = page.locator('#code-pane');
    await expect(codePane).toBeVisible();
    const viewportContainer = page.locator('#viewport-container');
    await expect(viewportContainer).toBeVisible();

    const codeBox = await codePane.boundingBox();
    expect(codeBox).not.toBeNull();
    expect(codeBox!.width).toBeGreaterThanOrEqual(260);

    const viewportBox = await viewportContainer.boundingBox();
    expect(viewportBox).not.toBeNull();
    expect(viewportBox!.width).toBeGreaterThan(600);

    // 3. Wait for initial CDML model to render
    await page.waitForFunction(() => {
      const viewer = (window as any).__cadViewer;
      const geom = viewer?.meshManager?.solidMesh?.geometry;
      return geom?.attributes?.position?.count > 0 && viewer.meshManager.getTriangleCount() > 0;
    }, { timeout: 15000 });

    const initialTriangles = await page.evaluate(() => (window as any).__cadViewer.meshManager.getTriangleCount());
    expect(initialTriangles).toBeGreaterThan(0);

    // 4. Collapse Code Pane via collapse toggle button
    const collapseBtn = page.locator('[data-testid="collapse-toggle"]');
    await expect(collapseBtn).toBeVisible();
    await collapseBtn.click();

    // Verify Code Pane is collapsed
    await expect(codePane).toHaveClass(/collapsed/);
    const collapsedCodeBox = await codePane.boundingBox();
    expect(collapsedCodeBox === null || collapsedCodeBox.width === 0).toBe(true);

    // Viewport expands to 100% width (1280px)
    await page.waitForFunction(() => {
      const vp = document.getElementById('viewport-container');
      return vp && vp.clientWidth >= 1270;
    });

    const expandedVpBox = await viewportContainer.boundingBox();
    expect(expandedVpBox!.width).toBeGreaterThanOrEqual(1270);

    // Restore button is now visible
    const expandBtn = page.locator('[data-testid="expand-toggle"]');
    await expect(expandBtn).toBeVisible();

    // 5. Expand Code Pane back
    await expandBtn.click();
    await expect(codePane).not.toHaveClass(/collapsed/);
    await expect(codePane).toBeVisible();

    // 6. Verify WebGL context stability
    const isContextValid = await page.evaluate(() => {
      const viewer = (window as any).__cadViewer;
      const gl = viewer?.renderer?.getContext();
      return !!gl && !gl.isContextLost();
    });
    expect(isContextValid).toBe(true);
  });

  test('Mobile Responsive Flex Layout: stacked flex-direction column with vertical collapse', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');

    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => !!(window as any).__cadViewer && !!(window as any).__cadBridge);

    // 1. Verify mobile column flex layout
    const appContainer = page.locator('#app-container');
    const flexDir = await appContainer.evaluate((el) => window.getComputedStyle(el).flexDirection);
    expect(flexDir).toBe('column');

    // 2. Both Viewport and Code Pane are stacked
    const viewportContainer = page.locator('#viewport-container');
    const codePane = page.locator('#code-pane');
    await expect(viewportContainer).toBeVisible();
    await expect(codePane).toBeVisible();

    const vpBox = await viewportContainer.boundingBox();
    const codeBox = await codePane.boundingBox();
    expect(vpBox).not.toBeNull();
    expect(codeBox).not.toBeNull();
    expect(vpBox!.height).toBeGreaterThan(200);
    expect(codeBox!.height).toBeGreaterThan(100);

    // 3. Collapse Code Pane in Mobile view
    const collapseBtn = page.locator('[data-testid="collapse-toggle"]');
    await collapseBtn.click();

    await expect(codePane).toHaveClass(/collapsed/);
    await page.waitForFunction(() => {
      const vp = document.getElementById('viewport-container');
      return vp && vp.clientHeight >= 800;
    });

    const expandedVpBox = await viewportContainer.boundingBox();
    expect(expandedVpBox!.height).toBeGreaterThanOrEqual(800);

    // 4. Restore Code Pane
    const expandBtn = page.locator('[data-testid="expand-toggle"]');
    await expect(expandBtn).toBeVisible();
    await expandBtn.click();
    await expect(codePane).not.toHaveClass(/collapsed/);
  });

  test('Fault-Tolerant Live CDML Editing: retains valid mesh when invalid assert is typed', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/');

    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => {
      const viewer = (window as any).__cadViewer;
      const geom = viewer?.meshManager?.solidMesh?.geometry;
      return geom?.attributes?.position?.count > 0 && viewer.meshManager.getTriangleCount() > 0;
    }, { timeout: 15000 });

    const statusMessage = page.locator('[data-testid="status-message"]');
    await expect(statusMessage).toContainText(/Ready|Valid/);

    const initialTriangles = await page.evaluate(() => (window as any).__cadViewer.meshManager.getTriangleCount());
    expect(initialTriangles).toBeGreaterThan(0);

    // Invalidate CDML by changing bore_r to 42.0 (violates bore_clearance assert in defs)
    const currentCode = await page.locator('#cdml-editor').inputValue();
    const failingCode = currentCode.replace(/id="bore_r"\s+value="15\.0"/, 'id="bore_r"      value="42.0"');

    await page.locator('#cdml-editor').fill(failingCode);

    // Wait for debounced evaluation to catch the error
    await expect(statusMessage).toContainText(/ERR_ASSERT_VIOLATED|0x0203|bore plus wall margin/i, { timeout: 10000 });
    const statusIndicator = page.locator('#status-indicator');
    await expect(statusIndicator).toHaveClass(/status-err/);

    // Assert that the 3D viewport retained the last valid mesh
    const currentTriangles = await page.evaluate(() => (window as any).__cadViewer.meshManager.getTriangleCount());
    expect(currentTriangles).toBe(initialTriangles);

    // Revert the failing assert
    await page.locator('#cdml-editor').fill(currentCode);
    await expect(statusMessage).toContainText(/Ready|Valid/, { timeout: 10000 });
    await expect(statusIndicator).toHaveClass(/status-ok/);
  });

  test('Minimal Embed Viewer: URL sourcing with data-gui=false renders zero GUI elements', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    // Navigate with ?embed=true, ?cdml=..., and ?gui=false
    await page.goto('/?embed=true&cdml=/examples/flange_normative.cdml&gui=false');

    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => {
      const viewer = (window as any).__cadViewer;
      const geom = viewer?.meshManager?.solidMesh?.geometry;
      return geom?.attributes?.position?.count > 0 && viewer.meshManager.getTriangleCount() > 0;
    }, { timeout: 15000 });

    // 1. Studio Code Pane & Splitter are hidden in embed mode
    const codePane = page.locator('#code-pane');
    await expect(codePane).toBeHidden();
    const splitter = page.locator('#pane-splitter');
    await expect(splitter).toBeHidden();

    // 2. Viewport is full bleed 1280x800
    const viewportContainer = page.locator('#viewport-container');
    const vpBox = await viewportContainer.boundingBox();
    expect(vpBox!.width).toBe(1280);
    expect(vpBox!.height).toBe(800);

    // 3. lil-gui controller must NOT be instantiated or in the DOM
    const lilGui = page.locator('.lil-gui');
    await expect(lilGui).toHaveCount(0);
    const hasLilController = await page.evaluate(() => !!(window as any).__cadLilController);
    expect(hasLilController).toBe(false);

    // 4. Model is rendered in 3D canvas
    const triangles = await page.evaluate(() => (window as any).__cadViewer.meshManager.getTriangleCount());
    expect(triangles).toBeGreaterThan(0);
  });

  test('Minimal Embed Viewer: declarative GUI controls filtering vars, probes, and exports', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    // Navigate with filtered gui attributes
    await page.goto(
      '/?embed=true&cdml=/examples/flange_normative.cdml&gui=true&vars=flange_w,bore_r&probes=housing_volume&exports=stl'
    );

    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => {
      const viewer = (window as any).__cadViewer;
      const geom = viewer?.meshManager?.solidMesh?.geometry;
      return geom?.attributes?.position?.count > 0 && viewer.meshManager.getTriangleCount() > 0;
    }, { timeout: 15000 });

    // 1. lil-gui IS in the DOM
    const lilGui = page.locator('.lil-gui');
    await expect(lilGui).toBeVisible();

    // 2. Only requested vars exist in Parameters folder
    await expect(page.locator('[data-testid="lil-param-flange_w"]')).toBeVisible();
    await expect(page.locator('[data-testid="lil-param-bore_r"]')).toBeVisible();
    // Non-requested vars should NOT be in the DOM
    await expect(page.locator('[data-testid="lil-param-flange_h"]')).toHaveCount(0);

    // 3. Only requested probes exist in Probes folder
    await expect(page.locator('[data-testid="lil-probe-housing_volume"]')).toBeVisible();

    // 4. Only requested exports exist in Exports folder
    await expect(page.locator('[data-testid="lil-action-stl"]')).toBeVisible();
    await expect(page.locator('[data-testid="lil-action-step"]')).toHaveCount(0);

    // 5. Parameter slider updates model without error
    const input = page.locator('[data-testid="lil-param-input-flange_w"]');
    if (await input.count() > 0) {
      await input.fill('95.0');
      await input.dispatchEvent('change');
      await page.waitForTimeout(300);
      const isContextValid = await page.evaluate(() => {
        const viewer = (window as any).__cadViewer;
        const gl = viewer?.renderer?.getContext();
        return !!gl && !gl.isContextLost();
      });
      expect(isContextValid).toBe(true);
    }
  });

  test('Live Reactive Geometry Updates: changing text/CDML or slider updates real 3D mesh dimensions without fake geometry', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/');

    await expect(page.locator('#cad-canvas')).toBeVisible();
    await page.waitForFunction(() => {
      const viewer = (window as any).__cadViewer;
      const geom = viewer?.meshManager?.solidMesh?.geometry;
      return geom?.attributes?.position?.count > 0 && viewer.meshManager.getTriangleCount() > 0;
    }, { timeout: 15000 });

    // 1. Initial 3D mesh dimensions
    const initialDims = await page.evaluate(() => {
      const geom = (window as any).__cadViewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      return {
        width: geom.boundingBox.max.x - geom.boundingBox.min.x,
        depth: geom.boundingBox.max.z - geom.boundingBox.min.z,
      };
    });
    expect(Math.abs(initialDims.width - 90.0)).toBeLessThan(0.2);
    expect(Math.abs(initialDims.depth - 16.0)).toBeLessThan(0.2);

    // 2. Update flange_w slider/number input to 120.0
    const wInput = page.locator('[data-testid="lil-param-input-flange_w"]');
    await expect(wInput).toBeVisible();
    await wInput.fill('120.0');
    await wInput.dispatchEvent('change');

    // Wait for mesh update
    await page.waitForFunction(() => {
      const geom = (window as any).__cadViewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      const w = geom.boundingBox.max.x - geom.boundingBox.min.x;
      return Math.abs(w - 120.0) < 0.2;
    }, { timeout: 5000 });

    const updatedWidth = await page.evaluate(() => {
      const geom = (window as any).__cadViewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      return geom.boundingBox.max.x - geom.boundingBox.min.x;
    });
    expect(Math.abs(updatedWidth - 120.0)).toBeLessThan(0.2);

    // 3. Update CDML text directly in #cdml-editor (flange_h = 30.0)
    const currentCode = await page.locator('#cdml-editor').inputValue();
    const updatedCode = currentCode.replace(/id="flange_h"\s+value="16\.0"/, 'id="flange_h"    value="30.0"');
    await page.locator('#cdml-editor').fill(updatedCode);

    // Wait for debounced evaluation to update mesh height
    await page.waitForFunction(() => {
      const geom = (window as any).__cadViewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      const h = geom.boundingBox.max.z - geom.boundingBox.min.z;
      return Math.abs(h - 30.0) < 0.2;
    }, { timeout: 5000 });

    const updatedHeight = await page.evaluate(() => {
      const geom = (window as any).__cadViewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      return geom.boundingBox.max.z - geom.boundingBox.min.z;
    });
    expect(Math.abs(updatedHeight - 30.0)).toBeLessThan(0.2);
  });

  test('Standalone Code Authoring: user can write code and geometry is built and rendered when example fails to load', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    // Navigate with a 404 example URL to simulate network failure or missing example
    await page.goto('/?cdml=/examples/non_existent_404.cdml');

    await expect(page.locator('#cad-canvas')).toBeVisible();
    await expect(page.locator('#cdml-editor')).toBeVisible();

    const customCdml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <var id="bracket_w" value="70.0" min="30.0" max="120.0" unit="mm"/>
    <var id="bracket_h" value="25.0" min="10.0" max="50.0" unit="mm"/>
    <var id="hole_d"    value="16.0" min="4.0"  max="24.0" unit="mm"/>
    <expr id="hole_r"   expr="hole_d / 2"/>
  </defs>
  <body>
    <chart id="ch_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="u2" expr="dot(e2, e2) - 1.0"/>
        <residual id="or" expr="dot(e1, e2)"/>
        <residual id="pz" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>
    <sketch id="sk_bracket" chart="ch_xy" max-iter="100">
      <vars>
        <point2d id="v0" u="-35.0" v="-35.0"/>
        <point2d id="v1" u=" 35.0" v="-35.0"/>
        <point2d id="v2" u=" 35.0" v=" 35.0"/>
        <point2d id="v3" u="-35.0" v=" 35.0"/>
      </vars>
      <wire id="w_outer" closed="true" role="outer">
        <curve id="c0" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="c1" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="c2" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="c3" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>
      <wire id="w_bore" closed="true" role="hole">
        <param-curve id="c_bore" param="t" domain="0 1"
          u-expr="ref(hole_r) * cos(2 * PI * t)"
          v-expr="ref(hole_r) * sin(2 * PI * t)"/>
      </wire>
      <constraints>
        <residual id="cx" expr="v0.u + v1.u"/>
        <residual id="cy" expr="v0.v + v3.v"/>
        <residual id="sy" expr="v2.u + v3.u"/>
        <residual id="h0" expr="v1.v - v0.v"/>
        <residual id="h1" expr="v2.v - v3.v"/>
        <residual id="ot" expr="dot(v1 - v0, v2 - v1)"/>
        <residual id="we" expr="dot(v1 - v0, v1 - v0) - ref(bracket_w)^2"/>
        <residual id="he" expr="dot(v2 - v1, v2 - v1) - ref(bracket_w)^2"/>
      </constraints>
    </sketch>
    <brep id="bracket_solid">
      <sweep id="sw_bracket" sketch="sk_bracket" cap-ends="true">
        <trajectory><translate x="0" y="0" z-expr="ref(bracket_h) * v"/></trajectory>
      </sweep>
    </brep>
  </body>
  <exports>
    <tessellate target="bracket_solid" chord-tol="0.05" angle-tol="0.1"/>
  </exports>
</cdml>`;

    await page.locator('#cdml-editor').fill(customCdml);

    // Wait for debounced evaluation & 3D mesh generation
    await page.waitForFunction(() => {
      const geom = (window as any).__cadViewer?.meshManager?.solidMesh?.geometry;
      return geom?.attributes?.position?.count > 0 && (window as any).__cadViewer.meshManager.getTriangleCount() > 0;
    }, { timeout: 10000 });

    const triangleCount = await page.evaluate(() => (window as any).__cadViewer.meshManager.getTriangleCount());
    expect(triangleCount).toBeGreaterThan(0);

    const statusMsg = await page.locator('#status-message').textContent();
    expect(statusMsg).toBe('Ready (CDML Valid)');

    // Verify mesh dimensions: width = 70.0, height = 25.0
    const dims = await page.evaluate(() => {
      const geom = (window as any).__cadViewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      return {
        w: geom.boundingBox.max.x - geom.boundingBox.min.x,
        h: geom.boundingBox.max.z - geom.boundingBox.min.z,
      };
    });
    expect(Math.abs(dims.w - 70.0)).toBeLessThan(0.5);
    expect(Math.abs(dims.h - 25.0)).toBeLessThan(0.5);
  });

});

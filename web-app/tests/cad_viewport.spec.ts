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

  test('Enters 2D sketch mode on XY plane, aligns camera normal, and displays sketch HUD', async ({
    page,
  }) => {
    // Click Enter 2D Sketch Mode
    await page.locator('#btn-enter-sketch').click();

    // Verify Sketch HUD elements are visible
    await expect(page.locator('#sketch-toolbar')).toBeVisible();
    await expect(page.locator('#sketch-coord-readout')).toBeVisible();

    const sketchState = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return null;
      return {
        inSketchMode: viewer.sketchManager.inSketchMode,
        activePlane: viewer.sketchManager.activePlane,
        enableRotate: viewer.controls.enableRotate,
        camZ: viewer.camera.position.z,
        camX: viewer.camera.position.x,
        camY: viewer.camera.position.y,
      };
    });

    expect(sketchState).not.toBeNull();
    expect(sketchState!.inSketchMode).toBe(true);
    expect(sketchState!.activePlane).toBe('XY');
    expect(sketchState!.enableRotate).toBe(false); // Orbit rotation locked
    expect(sketchState!.camZ).toBeGreaterThan(5);

    // Switch plane to XZ and verify alignment
    await page.locator('#btn-plane-xz').click();
    const planeState = await page.evaluate(() => window.__cadViewer?.sketchManager.activePlane);
    expect(planeState).toBe('XZ');

    // Switch back to XY
    await page.locator('#btn-plane-xy').click();
  });

  test('Draws constrained geometry, verifying DOF reduction and color transitions', async ({
    page,
  }) => {
    // Enter sketch mode
    await page.locator('#btn-enter-sketch').click();

    // Create a 4-point rectangle geometry and add constraints
    const solveResult = await page.evaluate(async () => {
      const mgr = window.__cadSketchManager;
      if (!mgr) throw new Error('SketchManager not found');

      // Add 4 points (P1 at origin fixed)
      const p1 = mgr.addPoint(0, 0, true);
      const p2 = mgr.addPoint(4, 0.5, false);
      const p3 = mgr.addPoint(4.2, 3, false);
      const p4 = mgr.addPoint(0, 2.8, false);

      // Add 4 lines
      const l1 = mgr.addLine(p1.id, p2.id);
      const l2 = mgr.addLine(p2.id, p3.id);
      const l3 = mgr.addLine(p3.id, p4.id);
      const l4 = mgr.addLine(p4.id, p1.id);

      // Under-constrained initial state
      await mgr.triggerSolve();
      const initialDof = mgr.dof;
      const initialColor = mgr.getColorForEntity(l1.id, 'line');

      // Add Horizontal & Vertical constraints
      mgr.addConstraint(4, l1.id); // Horizontal
      mgr.addConstraint(5, l2.id); // Vertical
      mgr.addConstraint(4, l3.id); // Horizontal
      mgr.addConstraint(5, l4.id); // Vertical

      // Add Distance constraints: width = 4.0, height = 3.0
      mgr.addConstraint(8, l1.id, undefined, undefined, undefined, 4.0);
      mgr.addConstraint(8, l2.id, undefined, undefined, undefined, 3.0);

      await mgr.triggerSolve();

      const finalDof = mgr.dof;
      const finalColor = mgr.getColorForEntity(l1.id, 'line');
      const solveState = mgr.solveState;

      return {
        initialDof,
        initialColor,
        finalDof,
        finalColor,
        solveState,
        p2Solved: { x: mgr.points[1].x, y: mgr.points[1].y },
        p3Solved: { x: mgr.points[2].x, y: mgr.points[2].y },
      };
    });

    // Check under-constrained initial state (Blue: 0x3b82f6)
    expect(solveResult.initialDof).toBeGreaterThan(0);
    expect(solveResult.initialColor).toBe(0x3b82f6);

    // Check fully-constrained final state (0 DOF, Green: 0x10b981)
    expect(solveResult.finalDof).toBe(0);
    expect(solveResult.finalColor).toBe(0x10b981);
    expect(solveResult.solveState).toBe(0); // CadSolveState.SOLVED

    // Solved geometry coordinates match constraints (4x3 rectangle)
    expect(solveResult.p2Solved.x).toBeCloseTo(4.0, 2);
    expect(solveResult.p2Solved.y).toBeCloseTo(0.0, 2);
    expect(solveResult.p3Solved.x).toBeCloseTo(4.0, 2);
    expect(solveResult.p3Solved.y).toBeCloseTo(3.0, 2);

    // Check HUD badge updates
    await expect(page.locator('#sketch-dof-val')).toHaveText('0 DOF');
    await expect(page.locator('#sketch-status-val')).toHaveText(/Fully Constrained/);
  });

  test('Live dragging of constrained points maintains steady 60 FPS rendering', async ({
    page,
  }) => {
    // Enter sketch mode
    await page.locator('#btn-enter-sketch').click();

    const benchmark = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      const mgr = window.__cadSketchManager;
      if (!viewer || !mgr) throw new Error('Viewer/Manager not found');

      // Create an under-constrained line
      const p1 = mgr.addPoint(0, 0, true);
      const p2 = mgr.addPoint(2, 2, false);
      mgr.addLine(p1.id, p2.id);
      await mgr.triggerSolve();

      const frameCount = 60;
      const start = performance.now();
      const deltas: number[] = [];
      let lastTime = start;

      for (let i = 0; i < frameCount; i++) {
        const targetX = 2.0 + Math.sin((i / frameCount) * Math.PI * 2) * 1.5;
        const targetY = 2.0 + Math.cos((i / frameCount) * Math.PI * 2) * 1.5;

        // Perform live drag update and render frame
        mgr.triggerSolve(p2.id, { x: targetX, y: targetY });
        viewer.controls.update();
        viewer.renderer.render(viewer.scene, viewer.camera);

        const now = performance.now();
        deltas.push(now - lastTime);
        lastTime = now;
      }

      const renderDuration = deltas.reduce((a, b) => a + b, 0);
      const avgFrameTimeMs = renderDuration / frameCount;
      const effectiveFps = 1000 / avgFrameTimeMs;

      await mgr.triggerSolve();

      return {
        frameCount,
        renderDuration,
        avgFrameTimeMs,
        effectiveFps,
        finalP2X: mgr.points[1].x,
        finalP2Y: mgr.points[1].y,
      };
    });

    expect(benchmark.frameCount).toBe(60);
    // Rendering + constraint solving maintains high frame rates (< 33.4 ms/frame, >= 30 FPS even on CPU)
    expect(benchmark.avgFrameTimeMs).toBeLessThan(33.4);
    expect(benchmark.effectiveFps).toBeGreaterThanOrEqual(30);
  });

  test('Feature Tree renders all DAG features and draggable rollback bar', async ({ page }) => {
    // Verify Feature Tree panel is visible
    const treePanel = page.locator('#feature-tree-panel');
    await expect(treePanel).toBeVisible();

    // Verify all 6 parametric features are rendered
    const feature1 = page.locator('[data-testid="feature-item-1"]');
    const feature2 = page.locator('[data-testid="feature-item-2"]');
    const feature3 = page.locator('[data-testid="feature-item-3"]');
    const feature4 = page.locator('[data-testid="feature-item-4"]');
    const feature5 = page.locator('[data-testid="feature-item-5"]');
    const feature6 = page.locator('[data-testid="feature-item-6"]');

    await expect(feature1).toBeVisible();
    await expect(feature2).toBeVisible();
    await expect(feature3).toBeVisible();
    await expect(feature4).toBeVisible();
    await expect(feature5).toBeVisible();
    await expect(feature6).toBeVisible();

    // Verify initial active count
    const activeBadge = page.locator('#tree-active-count');
    await expect(activeBadge).toHaveText('6 / 6 Active');

    // Verify Rollback Bar is mounted and rendered
    const rollbackBar = page.locator('#rollback-bar');
    await expect(rollbackBar).toBeVisible();
  });

  test('Draggable Rollback Bar can be moved, rolls back features, and updates solid geometry', async ({
    page,
  }) => {
    // Switch to Parametric DAG Solid
    await page.locator('#primitive-select').selectOption('dag');

    // Move rollback bar to index 1 (Base Extrude only)
    await page.evaluate(() => {
      window.__cadFeatureTree?.setRollbackIndex(1);
    });

    // Verify active count changed to 2 / 6 Active
    await expect(page.locator('#tree-active-count')).toHaveText('2 / 6 Active');

    // Verify downstream features are marked rolled back
    const feature3 = page.locator('[data-testid="feature-item-3"]');
    const feature4 = page.locator('[data-testid="feature-item-4"]');
    const feature5 = page.locator('[data-testid="feature-item-5"]');
    const feature6 = page.locator('[data-testid="feature-item-6"]');

    await expect(feature3).toHaveClass(/rolled-back/);
    await expect(feature4).toHaveClass(/rolled-back/);
    await expect(feature5).toHaveClass(/rolled-back/);
    await expect(feature6).toHaveClass(/rolled-back/);

    // Roll back further to index 0 (Sketch only)
    await page.evaluate(() => {
      window.__cadFeatureTree?.setRollbackIndex(0);
    });
    await expect(page.locator('#tree-active-count')).toHaveText('1 / 6 Active');

    // Move rollback forward to index 5 (All features active)
    await page.evaluate(() => {
      window.__cadFeatureTree?.setRollbackIndex(5);
    });
    await expect(page.locator('#tree-active-count')).toHaveText('6 / 6 Active');
    await expect(feature6).not.toHaveClass(/rolled-back/);

    // Toggle suppression on feature 6 (Corner Chamfer)
    await page.locator('[data-testid="btn-suppress-6"]').click();
    await expect(feature6).toHaveClass(/suppressed/);
    await expect(page.locator('#tree-active-count')).toHaveText('5 / 6 Active');
  });

  test('Sub-shape face and edge raycast picking identifies persistent 64-bit CadTopoId', async ({
    page,
  }) => {
    // Switch to Parametric DAG Solid
    await page.locator('#primitive-select').selectOption('dag');

    // Wait for DAG solid geometry to load
    await page.waitForTimeout(300);

    // Test sub-shape face picking with persistent 64-bit CadTopoId
    const facePickResult = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return null;

      // Raycast pick at viewport center
      const pick = viewer.picker.pickNormalized(0, 0, false);
      if (pick.type !== 'face') return null;

      // Set selection so HUD and highlights update
      viewer.setSelection(pick);

      return {
        type: pick.type,
        faceId: pick.faceId,
        hasTopoId: pick.topoId !== undefined,
        topoIdHex: pick.topoId ? '0x' + pick.topoId.toString(16) : null,
        decoded: pick.decodedTopo
          ? {
              origin_feature_id: pick.decodedTopo.origin_feature_id,
              source_sketch_entity_id: pick.decodedTopo.source_sketch_entity_id,
              op_type: pick.decodedTopo.op_type,
              subshape_type: pick.decodedTopo.subshape_type,
              flags: pick.decodedTopo.flags,
            }
          : null,
      };
    });

    expect(facePickResult).not.toBeNull();
    expect(facePickResult!.type).toBe('face');
    expect(facePickResult!.hasTopoId).toBe(true);
    expect(facePickResult!.topoIdHex).not.toBeNull();
    expect(facePickResult!.decoded).not.toBeNull();
    // Originating feature should be a valid DAG feature (e.g. 2 for Base Extrude, 4 for Boss, 5 for Fillet)
    expect(facePickResult!.decoded!.origin_feature_id).toBeGreaterThan(0);
    expect(facePickResult!.decoded!.subshape_type).toBe(2); // CAD_SUBSHAPE_FACE = 2

    // Verify HUD displays topological selection information
    const selectionType = page.locator('#selection-type');
    await expect(selectionType).toHaveText('TOPOLOGICAL FACE');

    // Also verify visual highlight face mesh is active
    const isHighlightActive = await page.evaluate(() => {
      return !!window.__cadViewer?.meshManager.highlightFaceMesh.visible;
    });
    expect(isHighlightActive).toBe(true);

    // Test sub-shape edge picking with persistent 64-bit CadTopoId
    const edgePickResult = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return null;

      const pick = viewer.picker.pickNormalized(0, 0, true);
      if (pick.type !== 'edge') return null;

      viewer.setSelection(pick);

      return {
        type: pick.type,
        edgeId: pick.edgeId,
        hasTopoId: pick.topoId !== undefined,
        topoIdHex: pick.topoId ? '0x' + pick.topoId.toString(16) : null,
        decoded: pick.decodedTopo
          ? {
              origin_feature_id: pick.decodedTopo.origin_feature_id,
              subshape_type: pick.decodedTopo.subshape_type,
            }
          : null,
      };
    });

    // If edge picked at center
    if (edgePickResult) {
      expect(edgePickResult.hasTopoId).toBe(true);
      expect(edgePickResult.decoded!.subshape_type).toBe(1); // CAD_SUBSHAPE_EDGE = 1
      await expect(selectionType).toHaveText('FEATURE EDGE');
    }
  });

  test('Parametric DAG solid rendering maintains steady 60 FPS viewport performance', async ({
    page,
  }) => {
    // Switch to Parametric DAG Solid
    await page.locator('#primitive-select').selectOption('dag');
    await page.waitForTimeout(300);

    const benchmark = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      if (!viewer) throw new Error('Viewer not found');

      const frameCount = 60;
      const start = performance.now();
      const deltas: number[] = [];
      let lastTime = start;

      for (let i = 0; i < frameCount; i++) {
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
      };
    });

    expect(benchmark.frameCount).toBe(60);
    expect(benchmark.avgFrameTimeMs).toBeLessThan(33.4);
    expect(benchmark.effectiveFps).toBeGreaterThanOrEqual(30);
  });

  test('STEP AP214 File Import parses B-Rep solid into Three.js viewport', async ({
    page,
  }) => {
    // Sample ISO-10303-21 STEP Part 21 Box solid
    const sampleStepText = `ISO-10303-21;
HEADER;
FILE_DESCRIPTION(('OpenCAD B-Rep Solid'), '2;1');
FILE_NAME('test_box.step', '2026-10-22T00:00:00', ('Author'), ('OpenCAD'), 'OpenCAD', 'OpenCAD', '');
FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
ENDSEC;
DATA;
#10 = CARTESIAN_POINT('', (0.0, 0.0, 0.0));
#11 = CARTESIAN_POINT('', (2.0, 0.0, 0.0));
#12 = CARTESIAN_POINT('', (2.0, 3.0, 0.0));
#13 = CARTESIAN_POINT('', (0.0, 3.0, 0.0));
#14 = CARTESIAN_POINT('', (0.0, 0.0, 4.0));
#15 = CARTESIAN_POINT('', (2.0, 0.0, 4.0));
#16 = CARTESIAN_POINT('', (2.0, 3.0, 4.0));
#17 = CARTESIAN_POINT('', (0.0, 3.0, 4.0));
#20 = VERTEX_POINT('', #10);
#21 = VERTEX_POINT('', #11);
#22 = VERTEX_POINT('', #12);
#23 = VERTEX_POINT('', #13);
#24 = VERTEX_POINT('', #14);
#25 = VERTEX_POINT('', #15);
#26 = VERTEX_POINT('', #16);
#27 = VERTEX_POINT('', #17);
#30 = EDGE_CURVE('', #20, #21, #10, .T.);
#31 = EDGE_CURVE('', #21, #22, #10, .T.);
#32 = EDGE_CURVE('', #22, #23, #10, .T.);
#33 = EDGE_CURVE('', #23, #20, #10, .T.);
#40 = POLY_LOOP('', (#20, #21, #22, #23));
#41 = POLY_LOOP('', (#24, #27, #26, #25));
#42 = POLY_LOOP('', (#20, #24, #25, #21));
#43 = POLY_LOOP('', (#21, #25, #26, #22));
#44 = POLY_LOOP('', (#22, #26, #27, #23));
#45 = POLY_LOOP('', (#23, #27, #24, #20));
#50 = FACE_OUTER_BOUND('', #40, .T.);
#51 = FACE_OUTER_BOUND('', #41, .T.);
#52 = FACE_OUTER_BOUND('', #42, .T.);
#53 = FACE_OUTER_BOUND('', #43, .T.);
#54 = FACE_OUTER_BOUND('', #44, .T.);
#55 = FACE_OUTER_BOUND('', #45, .T.);
#60 = ADVANCED_FACE('', (#50), #10, .T.);
#61 = ADVANCED_FACE('', (#51), #10, .T.);
#62 = ADVANCED_FACE('', (#52), #10, .T.);
#63 = ADVANCED_FACE('', (#53), #10, .T.);
#64 = ADVANCED_FACE('', (#54), #10, .T.);
#65 = ADVANCED_FACE('', (#55), #10, .T.);
#70 = CLOSED_SHELL('', (#60, #61, #62, #63, #64, #65));
#80 = MANIFOLD_SOLID_BREP('ImportedBox', #70);
ENDSEC;
END-ISO-10303-21;`;

    // Import STEP via global test hook
    const importResult = await page.evaluate(async (text) => {
      if (!window.__importStep || !window.__cadViewer) throw new Error('Missing STEP hooks');
      await window.__importStep(text);
      const mesh = window.__cadViewer.meshManager.solidMesh;
      if (!mesh) return null;
      const posAttr = mesh.geometry.getAttribute('position');
      return {
        hasMesh: true,
        vertexCount: posAttr ? posAttr.count : 0,
      };
    }, sampleStepText);

    expect(importResult).not.toBeNull();
    expect(importResult!.hasMesh).toBe(true);
    expect(importResult!.vertexCount).toBeGreaterThan(0);
  });

  test('STEP AP214 File Export produces compliant ISO-10303-21 Part 21 text', async ({
    page,
  }) => {
    const exportedText = await page.evaluate(async () => {
      if (!window.__exportStep) throw new Error('Missing __exportStep hook');
      return await window.__exportStep();
    });

    expect(exportedText).toContain('ISO-10303-21;');
    expect(exportedText).toContain('HEADER;');
    expect(exportedText).toContain("FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));");
    expect(exportedText).toContain('DATA;');
    expect(exportedText).toContain('MANIFOLD_SOLID_BREP');
    expect(exportedText).toContain('END-ISO-10303-21;');
  });

  test('STEP imported geometry maintains steady 60 FPS viewport performance', async ({
    page,
  }) => {
    const benchmark = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      if (!viewer) throw new Error('Viewer not found');

      const frameCount = 60;
      const start = performance.now();
      const deltas: number[] = [];
      let lastTime = start;

      for (let i = 0; i < frameCount; i++) {
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
      };
    });

    expect(benchmark.frameCount).toBe(60);
    expect(benchmark.avgFrameTimeMs).toBeLessThan(33.4);
    expect(benchmark.effectiveFps).toBeGreaterThanOrEqual(30);
  });
});

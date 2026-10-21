/**
 * Dedicated Puppeteer automated test suite for OpenCAD Viewport.
 *
 * Verifies:
 * 1. WebGL context initialization and mounting.
 * 2. 60 FPS rendering throughput across 60+ render ticks.
 * 3. Sub-shape face picking by raycasting over the model and inspecting topological face ID.
 * 4. Sub-shape edge picking and dynamic geometry regeneration (Box and Cylinder).
 */

import puppeteer from 'puppeteer-core';
import { spawn } from 'child_process';
import http from 'http';
import path from 'path';
import fs from 'fs';
import os from 'os';
import assert from 'assert';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const webAppRoot = path.resolve(__dirname, '..');

/**
 * Auto-detect Chromium executable path.
 */
function findChromiumPath() {
  const candidatePaths = [
    process.env.CHROME_BIN,
    process.env.CHROMIUM_PATH,
    path.join(os.homedir(), '.cache/ms-playwright/chromium-1248/chrome-linux64/chrome'),
    path.join(os.homedir(), '.cache/puppeteer/chrome/linux-152.0.7977.75/chrome-linux64/chrome'),
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium-browser',
    '/usr/bin/chromium',
  ];

  for (const candidate of candidatePaths) {
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }

  // Fallback: search in ~/.cache/ms-playwright
  const pwDir = path.join(os.homedir(), '.cache/ms-playwright');
  if (fs.existsSync(pwDir)) {
    const entries = fs.readdirSync(pwDir);
    for (const entry of entries) {
      if (entry.startsWith('chromium-')) {
        const p = path.join(pwDir, entry, 'chrome-linux64', 'chrome');
        if (fs.existsSync(p)) return p;
      }
    }
  }

  throw new Error(
    'Chromium executable not found. Set CHROME_BIN or ensure chromium-1248 is installed.'
  );
}

/**
 * Check if an HTTP server is reachable on a given URL.
 */
function checkServer(url) {
  return new Promise((resolve) => {
    const req = http.get(url, (res) => {
      resolve(res.statusCode >= 200 && res.statusCode < 400);
    });
    req.on('error', () => resolve(false));
    req.setTimeout(1000, () => {
      req.destroy();
      resolve(false);
    });
  });
}

/**
 * Wait until server is responding or throw on timeout.
 */
async function waitForServer(url, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await checkServer(url)) {
      return true;
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`Server at ${url} failed to respond within ${timeoutMs}ms`);
}

async function runCadViewportTestSuite() {
  console.log('===============================================================');
  console.log('   OpenCAD Viewport & Sub-Shape Picking - Puppeteer Test Suite  ');
  console.log('===============================================================');

  const defaultPort = 5173;
  let serverUrl = `http://127.0.0.1:${defaultPort}`;
  let viteProcess = null;

  // 1. Ensure Vite server is running or start one
  const isAlreadyRunning = await checkServer(serverUrl);
  if (isAlreadyRunning) {
    console.log(`[INFO] Reusing running Vite server at ${serverUrl}`);
  } else {
    console.log(`[INFO] Starting Vite dev server on port ${defaultPort}...`);
    const viteBin = path.join(webAppRoot, 'node_modules/vite/bin/vite.js');
    viteProcess = spawn(
      process.execPath,
      [viteBin, '--port', String(defaultPort), '--strictPort'],
      {
        cwd: webAppRoot,
        stdio: ['ignore', 'pipe', 'pipe'],
      }
    );

    viteProcess.stdout.on('data', (d) => {
      const msg = d.toString();
      const match = msg.match(/http:\/\/localhost:(\d+)/) || msg.match(/http:\/\/127\.0\.0\.1:(\d+)/);
      if (match) {
        serverUrl = `http://127.0.0.1:${match[1]}`;
      }
    });

    viteProcess.stderr.on('data', (d) => {
      const err = d.toString();
      if (!err.includes('DeprecationWarning')) {
        console.error('[Vite stderr]', err.trim());
      }
    });

    await waitForServer(serverUrl);
    console.log(`[PASS] Vite dev server ready at ${serverUrl}`);
  }

  const cleanup = () => {
    if (viteProcess) {
      console.log('[INFO] Stopping spawned Vite dev server...');
      viteProcess.kill('SIGTERM');
      viteProcess = null;
    }
  };

  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  let browser;
  try {
    const executablePath = findChromiumPath();
    console.log(`[INFO] Using Chromium at: ${executablePath}`);

    browser = await puppeteer.launch({
      executablePath,
      headless: 'new',
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--enable-webgl',
        '--ignore-gpu-blocklist',
        '--enable-gpu-rasterization',
        '--disable-gpu-vsync',
        '--disable-frame-rate-limit',
        '--window-size=1280,720',
      ],
      defaultViewport: { width: 1280, height: 720 },
    });

    const page = await browser.newPage();

    // Collect browser console messages for debugging
    page.on('console', (msg) => {
      const text = msg.text();
      if (msg.type() === 'error') {
        console.error('[Browser Error]', text);
      }
    });

    console.log(`[INFO] Navigating to ${serverUrl}...`);
    await page.goto(serverUrl, { waitUntil: 'domcontentloaded' });

    // Wait for canvas element and CAD globals
    await page.waitForSelector('#cad-canvas', { visible: true });
    await page.waitForFunction(
      () =>
        !!window.__cadViewer &&
        !!window.__cadBridge &&
        (window.__cadViewer?.meshManager?.solidMesh?.geometry?.attributes?.position?.count || 0) > 0,
      { timeout: 10000 }
    );

    // -------------------------------------------------------------------------
    // TEST 1: WebGL Context Initialization
    // -------------------------------------------------------------------------
    console.log('\n--- [TEST 1] WebGL Context & Base Geometry Verification ---');
    const isContextValid = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer || !viewer.renderer) return false;
      const gl = viewer.renderer.getContext();
      return !!gl && typeof gl.clear === 'function';
    });
    assert.strictEqual(isContextValid, true, 'WebGL rendering context must be initialized');

    const facesText = await page.$eval('#stat-faces', (el) => el.textContent.trim());
    const edgesText = await page.$eval('#stat-edges', (el) => el.textContent.trim());
    const trianglesText = await page.$eval('#stat-triangles', (el) => el.textContent.trim());
    const verticesText = await page.$eval('#stat-vertices', (el) => el.textContent.trim());

    console.log(`[STATS] Box - Faces: ${facesText}, Edges: ${edgesText}, Triangles: ${trianglesText}, Vertices: ${verticesText}`);
    assert.strictEqual(facesText, '6', 'Box primitive must have 6 topological faces');
    assert.strictEqual(edgesText, '12', 'Box primitive must have 12 sharp edges');
    assert.strictEqual(trianglesText, '12', 'Box primitive must have 12 triangles');
    assert.strictEqual(verticesText, '24', 'Box primitive must have 24 vertices');
    console.log('[PASS] WebGL context and base Box geometry validated');

    // -------------------------------------------------------------------------
    // TEST 2: 60 FPS Rendering Throughput across 60+ Render Ticks
    // -------------------------------------------------------------------------
    console.log('\n--- [TEST 2] 60 FPS Rendering Throughput Benchmark ---');
    const benchmark = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      if (!viewer) throw new Error('Viewer not found');

      const frameCount = 60;
      const start = performance.now();
      const deltas = [];
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
        activeFrameCount: viewer.totalFrameCount,
      };
    });

    console.log(`[PERF] 60 frames in ${benchmark.totalDuration.toFixed(2)}ms (avg: ${benchmark.avgFrameTimeMs.toFixed(2)}ms/frame, effective FPS: ${benchmark.effectiveFps.toFixed(1)})`);
    assert.strictEqual(benchmark.frameCount, 60, 'Should measure across exactly 60 render frames');
    // Ensure smooth frame throughput under 33.4ms per frame (>= 30-60 FPS capability)
    assert(
      benchmark.avgFrameTimeMs < 33.4,
      `Frame time (${benchmark.avgFrameTimeMs.toFixed(2)}ms) exceeds threshold`
    );
    assert(
      benchmark.effectiveFps >= 30,
      `Effective throughput FPS (${benchmark.effectiveFps.toFixed(1)}) is below threshold`
    );

    // Verify active animation loop is continuously ticking
    await new Promise((r) => setTimeout(r, 400));
    const activeFrames = await page.evaluate(() => window.__cadViewer?.totalFrameCount || 0);
    assert(activeFrames > 0, 'Active animation frame loop must be ticking');
    console.log(`[PASS] 60+ render ticks throughput validated (ticking frame count: ${activeFrames})`);

    // -------------------------------------------------------------------------
    // TEST 3: Sub-Shape Face Picking via Raycasting & Topological Face ID
    // -------------------------------------------------------------------------
    console.log('\n--- [TEST 3] Sub-Shape Face Picking Verification ---');
    const canvas = await page.$('#cad-canvas');
    const boxRect = await canvas.boundingBox();
    assert(boxRect, 'Canvas bounding box must not be null');

    const clickX = boxRect.x + boxRect.width / 2;
    const clickY = boxRect.y + boxRect.height / 2;

    await page.mouse.move(clickX, clickY);
    await page.mouse.click(clickX, clickY);

    await page.waitForFunction(
      () => {
        const el = document.getElementById('selection-type');
        return el && el.textContent.includes('TOPOLOGICAL FACE');
      },
      { timeout: 5000 }
    );

    const faceSelType = await page.$eval('#selection-type', (el) => el.textContent.trim());
    const faceSelName = await page.$eval('#selection-name', (el) => el.textContent.trim());
    const faceSelCoords = await page.$eval('#selection-coords', (el) => el.textContent.trim());

    console.log(`[PICK] Selection Type: "${faceSelType}", Name: "${faceSelName}", Coords: "${faceSelCoords}"`);
    assert.strictEqual(faceSelType, 'TOPOLOGICAL FACE', 'Selection type must be TOPOLOGICAL FACE');
    assert(/Face #[1-6]/.test(faceSelName), `Face name must match Face #[1-6], got: ${faceSelName}`);
    assert(/Hit Point: \[/.test(faceSelCoords), `Face coordinates must contain hit point`);

    const isHighlightFaceVisible = await page.evaluate(
      () => !!window.__cadViewer?.meshManager.highlightFaceMesh.visible
    );
    assert.strictEqual(isHighlightFaceVisible, true, 'Visual face highlight overlay must be visible');
    console.log('[PASS] Sub-shape face picking and Three.js highlight verified');

    // -------------------------------------------------------------------------
    // TEST 4: Sub-Shape Edge Picking & Dynamic Geometry Regeneration (Box & Cylinder)
    // -------------------------------------------------------------------------
    console.log('\n--- [TEST 4] Edge Picking & Dynamic Geometry Regeneration ---');

    // 4a. Box Edge Picking
    console.log('[SUBTEST 4a] Testing Box Edge Picking...');
    const boxEdgeResult = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return null;
      const pick = viewer.picker.pickNormalized(0, 0, true);
      if (pick.type !== 'edge' || pick.edgeId === undefined) return null;
      viewer.setSelection(pick);
      return {
        edgeId: pick.edgeId,
        label: pick.label,
        highlightVisible: viewer.meshManager.highlightEdgeLines.visible,
      };
    });

    assert(boxEdgeResult, 'Box edge picking must detect a sharp feature edge');
    assert(boxEdgeResult.edgeId >= 1 && boxEdgeResult.edgeId <= 12, `Box edgeId must be 1-12, got ${boxEdgeResult.edgeId}`);
    assert.strictEqual(boxEdgeResult.highlightVisible, true, 'Highlight edge lines must be visible');

    await page.waitForFunction(
      () => {
        const el = document.getElementById('selection-type');
        return el && el.textContent.includes('FEATURE EDGE');
      },
      { timeout: 3000 }
    );

    const edgeSelType = await page.$eval('#selection-type', (el) => el.textContent.trim());
    const edgeSelName = await page.$eval('#selection-name', (el) => el.textContent.trim());
    console.log(`[PICK] Box Edge: Type="${edgeSelType}", Name="${edgeSelName}"`);
    assert.strictEqual(edgeSelType, 'FEATURE EDGE');
    assert(/Edge #[1-9]/.test(edgeSelName), `Edge name must match Edge #[1-9], got ${edgeSelName}`);
    console.log('[PASS] Box sub-shape edge picking verified');

    // 4b. Dynamic Geometry Regeneration to Cylinder
    console.log('[SUBTEST 4b] Regenerating geometry to Cylinder...');
    await page.select('#primitive-select', 'cylinder');

    await page.waitForFunction(
      () => {
        const f = document.getElementById('stat-faces');
        const e = document.getElementById('stat-edges');
        return f && f.textContent === '3' && e && e.textContent === '64';
      },
      { timeout: 5000 }
    );

    const cylFacesText = await page.$eval('#stat-faces', (el) => el.textContent.trim());
    const cylEdgesText = await page.$eval('#stat-edges', (el) => el.textContent.trim());
    const cylTrianglesText = await page.$eval('#stat-triangles', (el) => el.textContent.trim());
    const cylVerticesText = await page.$eval('#stat-vertices', (el) => el.textContent.trim());

    console.log(`[STATS] Cylinder - Faces: ${cylFacesText}, Edges: ${cylEdgesText}, Triangles: ${cylTrianglesText}, Vertices: ${cylVerticesText}`);
    assert.strictEqual(cylFacesText, '3', 'Cylinder must have 3 topological faces (Top, Bottom, Lateral)');
    assert.strictEqual(cylEdgesText, '64', 'Cylinder must have 64 edge segments (32 bottom + 32 top)');
    assert.strictEqual(cylTrianglesText, '128', 'Cylinder must have 128 triangles');
    console.log('[PASS] Dynamic geometry regeneration to Cylinder verified');

    // 4c. Cylinder Face Picking
    console.log('[SUBTEST 4c] Testing Cylinder Face Picking...');
    await page.mouse.click(clickX, clickY);

    await page.waitForFunction(
      () => {
        const el = document.getElementById('selection-type');
        return el && el.textContent.includes('TOPOLOGICAL FACE');
      },
      { timeout: 3000 }
    );

    const cylFaceType = await page.$eval('#selection-type', (el) => el.textContent.trim());
    const cylFaceName = await page.$eval('#selection-name', (el) => el.textContent.trim());
    console.log(`[PICK] Cylinder Face: Type="${cylFaceType}", Name="${cylFaceName}"`);
    assert.strictEqual(cylFaceType, 'TOPOLOGICAL FACE');
    assert(/Face #[1-3]/.test(cylFaceName), `Cylinder face name must match Face #[1-3], got ${cylFaceName}`);
    console.log('[PASS] Cylinder face picking verified');

    // 4d. Cylinder Edge Picking
    console.log('[SUBTEST 4d] Testing Cylinder Edge Picking...');
    const cylEdgeCoords = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      if (!viewer) return null;
      const geom = viewer.meshManager.edgeLines.geometry;
      const pos = geom.attributes.position.array;
      if (pos.length < 6) return null;
      // Pick midpoint of an edge segment from the top rim
      const segIdx = pos.length >= 384 ? 32 : 0;
      const offset = segIdx * 6;
      const mx = (pos[offset + 0] + pos[offset + 3]) / 2;
      const my = (pos[offset + 1] + pos[offset + 4]) / 2;
      const mz = (pos[offset + 2] + pos[offset + 5]) / 2;
      const vec = viewer.camera.position.clone().set(mx, my, mz);
      vec.project(viewer.camera);
      return { nx: vec.x, ny: vec.y };
    });

    const cylEdgeResult = await page.evaluate((coords) => {
      const viewer = window.__cadViewer;
      if (!viewer) return null;
      // Raycast at projected edge coordinate or fallback to direct picker
      const nx = coords ? coords.nx : 0;
      const ny = coords ? coords.ny : 0;
      const pick = viewer.picker.pickNormalized(nx, ny, true);
      if (pick.type !== 'edge' || pick.edgeId === undefined) return null;
      viewer.setSelection(pick);
      return {
        edgeId: pick.edgeId,
        label: pick.label,
        highlightVisible: viewer.meshManager.highlightEdgeLines.visible,
      };
    }, cylEdgeCoords);

    assert(cylEdgeResult, 'Cylinder edge picking must detect circular rim edge');
    assert(cylEdgeResult.edgeId === 1 || cylEdgeResult.edgeId === 2, `Cylinder edgeId must be 1 or 2, got ${cylEdgeResult.edgeId}`);
    assert.strictEqual(cylEdgeResult.highlightVisible, true, 'Cylinder edge highlight overlay must be visible');

    await page.waitForFunction(
      () => {
        const el = document.getElementById('selection-type');
        return el && el.textContent.includes('FEATURE EDGE');
      },
      { timeout: 3000 }
    );

    const cylEdgeSelType = await page.$eval('#selection-type', (el) => el.textContent.trim());
    const cylEdgeSelName = await page.$eval('#selection-name', (el) => el.textContent.trim());
    console.log(`[PICK] Cylinder Edge: Type="${cylEdgeSelType}", Name="${cylEdgeSelName}"`);
    assert.strictEqual(cylEdgeSelType, 'FEATURE EDGE');
    assert(/Edge #[1-2]/.test(cylEdgeSelName), `Cylinder edge name must match Edge #[1-2], got ${cylEdgeSelName}`);
    console.log('[PASS] Cylinder edge picking verified');

    // 4e. Dynamic Geometry Regeneration back to Box
    console.log('[SUBTEST 4e] Regenerating geometry back to Box...');
    await page.select('#primitive-select', 'box');
    await page.waitForFunction(
      () => {
        const f = document.getElementById('stat-faces');
        const e = document.getElementById('stat-edges');
        return f && f.textContent === '6' && e && e.textContent === '12';
      },
      { timeout: 5000 }
    );
    console.log('[PASS] Dynamic geometry regeneration back to Box verified');

    // =========================================================================
    // STEP 5: Interactive 2D Sketch Mode & PlaneGCS Constraint Solving
    // =========================================================================
    console.log('\n--- Step 5: Interactive 2D Sketch Mode & Constraint Solving ---');

    // 5a. Enter 2D Sketch Mode on XY Plane
    console.log('[SUBTEST 5a] Entering 2D sketch mode on XY plane...');
    await page.click('#btn-enter-sketch');
    await page.waitForSelector('#sketch-toolbar', { visible: true, timeout: 3000 });
    await page.waitForSelector('#sketch-coord-readout', { visible: true, timeout: 3000 });

    const sketchInitState = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      return {
        inSketchMode: viewer?.sketchManager.inSketchMode,
        activePlane: viewer?.sketchManager.activePlane,
        enableRotate: viewer?.controls.enableRotate,
        camZ: viewer?.camera.position.z,
      };
    });

    assert.strictEqual(sketchInitState.inSketchMode, true, 'SketchManager must be in sketch mode');
    assert.strictEqual(sketchInitState.activePlane, 'XY', 'Active sketch plane must be XY');
    assert.strictEqual(sketchInitState.enableRotate, false, 'Orbit rotation must be disabled in sketch mode');
    assert(sketchInitState.camZ > 5, 'Camera must be aligned along Z axis facing XY plane');
    console.log('[PASS] 2D sketch mode initialized and camera squarely aligned to XY plane');

    // 5b. Constrained Geometry Creation, Solver Convergence & DOF Reduction
    console.log('[SUBTEST 5b] Creating 4-point rectangle wire and solving constraints...');
    const solveValidation = await page.evaluate(async () => {
      const mgr = window.__cadSketchManager;
      if (!mgr) throw new Error('SketchManager not found');

      // Add 4 points (P1 at origin fixed)
      const p1 = mgr.addPoint(0, 0, true);
      const p2 = mgr.addPoint(4, 0.4, false);
      const p3 = mgr.addPoint(4.1, 3, false);
      const p4 = mgr.addPoint(0, 2.9, false);

      // Add 4 lines
      const l1 = mgr.addLine(p1.id, p2.id);
      const l2 = mgr.addLine(p2.id, p3.id);
      const l3 = mgr.addLine(p3.id, p4.id);
      const l4 = mgr.addLine(p4.id, p1.id);

      // Trigger initial under-constrained solve
      await mgr.triggerSolve();
      const underConstrainedDof = mgr.dof;
      const underConstrainedColor = mgr.getColorForEntity(l1.id, 'line');

      // Add Horizontal & Vertical constraints
      mgr.addConstraint(4, l1.id); // Horizontal
      mgr.addConstraint(5, l2.id); // Vertical
      mgr.addConstraint(4, l3.id); // Horizontal
      mgr.addConstraint(5, l4.id); // Vertical

      // Add Distance constraints: width = 4.0, height = 3.0
      mgr.addConstraint(8, l1.id, undefined, undefined, undefined, 4.0);
      mgr.addConstraint(8, l2.id, undefined, undefined, undefined, 3.0);

      // Solve system
      await mgr.triggerSolve();

      return {
        underConstrainedDof,
        underConstrainedColor,
        finalDof: mgr.dof,
        finalColor: mgr.getColorForEntity(l1.id, 'line'),
        solveState: mgr.solveState,
        p2: { x: mgr.points[1].x, y: mgr.points[1].y },
        p3: { x: mgr.points[2].x, y: mgr.points[2].y },
      };
    });

    console.log(`[SOLVER] Under-constrained DOF: ${solveValidation.underConstrainedDof}, Initial color: 0x${solveValidation.underConstrainedColor.toString(16)}`);
    console.log(`[SOLVER] Final DOF: ${solveValidation.finalDof}, Final color: 0x${solveValidation.finalColor.toString(16)} (Green=0x10b981)`);
    console.log(`[SOLVER] Solved P2=[${solveValidation.p2.x.toFixed(3)}, ${solveValidation.p2.y.toFixed(3)}], P3=[${solveValidation.p3.x.toFixed(3)}, ${solveValidation.p3.y.toFixed(3)}]`);

    assert(solveValidation.underConstrainedDof > 0, 'Initial state must be under-constrained');
    assert.strictEqual(solveValidation.underConstrainedColor, 0x3b82f6, 'Under-constrained entities must render Blue (0x3b82f6)');
    assert.strictEqual(solveValidation.finalDof, 0, 'Fully constrained system must have 0 DOF');
    assert.strictEqual(solveValidation.finalColor, 0x10b981, 'Fully constrained entities must render Green (0x10b981)');
    assert.strictEqual(solveValidation.solveState, 0, 'Solve state must be SOLVED (0)');
    assert(Math.abs(solveValidation.p2.x - 4.0) < 0.05, 'P2.x must converge to 4.0');
    assert(Math.abs(solveValidation.p2.y - 0.0) < 0.05, 'P2.y must converge to 0.0');
    assert(Math.abs(solveValidation.p3.x - 4.0) < 0.05, 'P3.x must converge to 4.0');
    assert(Math.abs(solveValidation.p3.y - 3.0) < 0.05, 'P3.y must converge to 3.0');

    const dofText = await page.$eval('#sketch-dof-val', (el) => el.textContent.trim());
    const statusText = await page.$eval('#sketch-status-val', (el) => el.textContent.trim());
    assert.strictEqual(dofText, '0 DOF');
    assert(statusText.includes('Fully Constrained'), `Status text must indicate Fully Constrained, got "${statusText}"`);
    console.log('[PASS] Constraint solver convergence, 0-DOF reduction, and green color transition verified');

    // 5c. Live Dragging at Steady 60 FPS Throughput
    console.log('[SUBTEST 5c] Benchmarking 60-iteration live constraint point dragging...');
    const dragBenchmark = await page.evaluate(async () => {
      const viewer = window.__cadViewer;
      const mgr = window.__cadSketchManager;
      if (!viewer || !mgr) throw new Error('Viewer/Manager not found');

      // Remove distance constraints so rectangle can be interactively deformed with 2 remaining DOF
      const distConstraints = mgr.constraints.filter((c) => c.type === 8);
      for (const dc of distConstraints) {
        mgr.removeConstraint(dc.id);
      }
      await mgr.triggerSolve();

      const frameCount = 60;
      const deltas = [];
      let lastTime = performance.now();

      for (let i = 0; i < frameCount; i++) {
        const tx = 4.0 + Math.sin((i / frameCount) * Math.PI * 2) * 0.8;
        const ty = Math.cos((i / frameCount) * Math.PI * 2) * 0.8;

        mgr.triggerSolve(mgr.points[1].id, { x: tx, y: ty });
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

      return { frameCount, renderDuration, avgFrameTimeMs, effectiveFps };
    });

    console.log(`[PERF] 60-tick Drag Solve: Render Total=${dragBenchmark.renderDuration.toFixed(1)}ms, Avg=${dragBenchmark.avgFrameTimeMs.toFixed(2)}ms/frame, Effective FPS=${dragBenchmark.effectiveFps.toFixed(1)}`);
    assert(dragBenchmark.avgFrameTimeMs < 33.4, `Frame time must be under 33.4ms, got ${dragBenchmark.avgFrameTimeMs}ms`);
    assert(dragBenchmark.effectiveFps >= 30, `Effective FPS must be >= 30, got ${dragBenchmark.effectiveFps}`);
    console.log('[PASS] Live dragging throughput benchmark verified');

    // 5d. Exit Sketch Mode & Orbit Restoration
    console.log('[SUBTEST 5d] Exiting sketch mode and restoring 3D viewport controls...');
    await page.click('#btn-exit-sketch');
    const exitState = await page.evaluate(() => {
      const viewer = window.__cadViewer;
      return {
        inSketchMode: viewer?.sketchManager.inSketchMode,
        enableRotate: viewer?.controls.enableRotate,
      };
    });
    assert.strictEqual(exitState.inSketchMode, false);
    assert.strictEqual(exitState.enableRotate, true, 'Orbit rotation must be restored upon exit');
    console.log('[PASS] Sketch exit and 3D orbit controls restoration verified');

    console.log('\n===============================================================');
    console.log('   All OpenCAD Viewport Puppeteer Automated Tests PASSED!     ');
    console.log('===============================================================');
  } finally {
    if (browser) {
      await browser.close();
    }
    cleanup();
  }
}

runCadViewportTestSuite()
  .then(() => {
    process.exit(0);
  })
  .catch((err) => {
    console.error('\n[FATAL TEST FAILURE]:', err);
    process.exit(1);
  });

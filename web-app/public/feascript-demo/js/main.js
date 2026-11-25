/**
 * @module main
 * Application orchestrator wiring OpenCadBridge, cdmlToFEAScriptGeometry,
 * solveThermal2D, Thermal3DViewport, Fem2DViewport, lil-gui, and dock actions.
 */

import GUI from 'lil-gui';
import { transformSolverOutputToVTP } from 'feascript';
import { OpenCadBridge } from './opencad-bridge.js';
import { cdmlToFEAScriptGeometry } from './cdml-to-feascript.js';
import { solveThermal2D, buildNearestWallFieldGrid } from './feascript-solver.js';
import { Thermal3DViewport, Fem2DViewport } from './viewports.js';
import { buildCDML } from './cdml-presets.js';

const params = {
  modelPreset: 'Cooling Plate (Rect + Bore)',
  W: 90,
  H: 60,
  outer_r: 30,
  thickness: 12,
  hole_r: 9.0,
  k_cond: 15.0,
  base_T: 180,
  top_h: 18,
  hole_T: 25,
  hole_h: 45,
  shading: 'Thermal Field',
  wireframe: false,
  target_T: 82,
  optimizeLoop: () => runClosedLoopOptimization(),
  resetDefaults: () => resetAllParams(),
  exportStep: () => downloadExport('step'),
  exportStl: () => downloadExport('stl'),
  exportVtp: () => downloadVTP(),
};

const viewState = { show3D: true, show2D: false };
let cad = null;
let lastFem = null;
let lastCdmlGeom = null;
let optimizing = false;

const pane3D = document.getElementById('pane-3d');
const pane2D = document.getElementById('pane-2d');
const vp3D = new Thermal3DViewport(document.getElementById('cad-3d-canvas'), pane3D);
const vp2D = new Fem2DViewport(document.getElementById('fem-2d-canvas'), pane2D, document.getElementById('fem-hover'));

function setTelemetryLoop(kind, text) {
  document.getElementById('tel-dot').className = `status-dot ${kind}`;
  document.getElementById('tel-loop').textContent = text;
}

function runCoupledStep(loopLabel = null) {
  if (!cad) return null;
  const t0 = performance.now();
  try {
    const isDisk = params.modelPreset === 'Annular Disk (Benchmark)';
    const maxSafeR = isDisk
      ? Math.max(4.0, params.outer_r - 4.5)
      : Math.max(5.0, params.H / 2 - 5.5);
    if (params.hole_r > maxSafeR) {
      params.hole_r = Math.floor(maxSafeR * 2) / 2;
      guiControllers.forEach((c) => c.updateDisplay());
    }

    const xml = buildCDML(params);
    const pass1 = cad.evalCdml(xml);
    const cdmlGeom = cdmlToFEAScriptGeometry(xml);
    lastCdmlGeom = cdmlGeom;

    const fem = solveThermal2D(cdmlGeom, params);
    lastFem = fem;

    const fieldGrid = buildNearestWallFieldGrid(fem, pass1.bbox, params);
    cad.writeFieldBuffer(fieldGrid);
    const pass2 = cad.evalCdml(xml);

    vp3D.updateMesh(pass2, fem, params);
    if (viewState.show2D) {
      vp2D.render(fem, cdmlGeom, params);
    }

    const loopMs = (performance.now() - t0).toFixed(0);
    setTelemetryLoop('ok', loopLabel || `LOOP: SYNCED (${loopMs} ms)`);
    const edgeLabel = isDisk
      ? `FEM Bore: ${fem.boreMeanT.toFixed(2)} °C`
      : `T(y=H): ${fem.edgeMeanT.toFixed(2)} °C`;
    document.getElementById('tel-thermal').textContent =
      `${edgeLabel} · Bore Probe: ${pass2.boreTempProbe.toFixed(2)} °C`;
    document.getElementById('tel-geom').textContent = isDisk
      ? `R=${params.outer_r} r=${params.hole_r} t=${params.thickness} mm · ${(pass2.volume / 1000).toFixed(2)} cm³`
      : `${params.W} × ${params.H} × ${params.thickness} mm · ${(pass2.volume / 1000).toFixed(2)} cm³`;
    document.getElementById('tel-mesh').textContent =
      `${fem.result.solutionVector.length} Nodes · ${fem.mesh.nodalNumbering.length} FEM Tri · ${pass2.triangleCount} B-Rep Tri`;
    document.getElementById('cb-min').textContent = `${fem.minT.toFixed(1)} °C`;
    document.getElementById('cb-mid').textContent = `${((fem.minT + fem.maxT) * 0.5).toFixed(1)} °C`;
    document.getElementById('cb-max').textContent = `${fem.maxT.toFixed(1)} °C`;
    return { pass2, fem, loopMs };
  } catch (err) {
    console.error(err);
    setTelemetryLoop('err', `ERR: ${err.message || err}`);
    return null;
  }
}

async function runClosedLoopOptimization() {
  if (optimizing || !cad) return;
  optimizing = true;
  const tStart = performance.now();
  const maxSafeR = params.modelPreset === 'Annular Disk (Benchmark)'
    ? Math.min(22.0, params.outer_r - 4.5)
    : Math.min(22.0, params.H / 2 - 5.5);
  for (let k = 0; k < 10; k++) {
    const res = runCoupledStep(`LOOP: ITERATING #${k + 1}…`);
    if (!res) break;
    const errT = res.fem.edgeMeanT - params.target_T;
    if (Math.abs(errT) <= 0.8) {
      const totalMs = (performance.now() - tStart).toFixed(0);
      setTelemetryLoop('ok', `LOOP: CONVERGED (${k + 1} iters · ${totalMs} ms)`);
      break;
    }
    if (errT > 0 && params.hole_r >= maxSafeR - 0.05) {
      setTelemetryLoop('ok', `LOOP: WALL LIMIT @ ${params.hole_r.toFixed(1)} mm`);
      break;
    }
    const step = Math.max(-2.0, Math.min(2.5, errT * 0.16));
    params.hole_r = Math.max(5.0, Math.min(maxSafeR, Math.round((params.hole_r + step) * 2) / 2));
    guiControllers.forEach((c) => c.updateDisplay());
    await new Promise((r) => setTimeout(r, 110));
  }
  optimizing = false;
}

function downloadExport(kind) {
  if (!cad) return;
  const bytes = cad.getExportBytes(kind);
  if (!bytes) return;
  const blob = new Blob([bytes], { type: kind === 'step' ? 'application/step' : 'model/stl' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `opencad_feascript_r${params.hole_r.toFixed(1)}.${kind}`;
  a.click();
  URL.revokeObjectURL(a.href);
}

async function downloadVTP() {
  if (!lastFem) return;
  const vtp = await transformSolverOutputToVTP(lastFem.model, lastFem.result, null, { mode: 'surface' });
  const blob = new Blob([vtp], { type: 'application/xml' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `feascript_thermal_r${params.hole_r.toFixed(1)}.vtp`;
  a.click();
  URL.revokeObjectURL(a.href);
}

// lil-gui setup
const gui = new GUI({ title: 'FEAScript × OpenCAD' });
if (window.innerWidth < 768) {
  gui.domElement.classList.add('hidden-gui');
  const btnGui = document.getElementById('btn-gui');
  btnGui.classList.remove('active');
  btnGui.setAttribute('aria-pressed', 'false');
}

const guiControllers = [];
let debounceId = null;
const scheduleSync = () => {
  clearTimeout(debounceId);
  debounceId = setTimeout(() => runCoupledStep(), 35);
};

const fGeom = gui.addFolder('Geometry (OpenCAD)');
guiControllers.push(
  fGeom.add(params, 'modelPreset', ['Cooling Plate (Rect + Bore)', 'Annular Disk (Benchmark)']).name('CDML Model').onChange((val) => {
    if (val === 'Annular Disk (Benchmark)') {
      Object.assign(params, { outer_r: 30, hole_r: 9.0, k_cond: 15.0, base_T: 180, hole_T: 25, hole_h: 540, target_T: 136.5 });
    } else {
      Object.assign(params, { W: 90, H: 60, hole_r: 9.0, k_cond: 15.0, base_T: 180, top_h: 18, hole_T: 25, hole_h: 45, target_T: 82 });
    }
    guiControllers.forEach((c) => c.updateDisplay());
    runCoupledStep();
  }),
  fGeom.add(params, 'W', 60, 120, 2).name('Width W (mm)').onChange(scheduleSync),
  fGeom.add(params, 'H', 44, 96, 2).name('Height H (mm)').onChange(scheduleSync),
  fGeom.add(params, 'outer_r', 18, 60, 1).name('Outer R (mm)').onChange(scheduleSync),
  fGeom.add(params, 'thickness', 4, 24, 1).name('Thickness (mm)').onChange(scheduleSync),
  fGeom.add(params, 'hole_r', 4, 22, 0.5).name('hole_r (mm)').onChange(scheduleSync)
);

const fBC = gui.addFolder('Boundary Conditions (FEA)');
guiControllers.push(
  fBC.add(params, 'k_cond', 1, 200, 1).name('Conduction k').onChange(scheduleSync),
  fBC.add(params, 'base_T', 60, 250, 5).name('Base/Rim T (°C)').onChange(scheduleSync),
  fBC.add(params, 'top_h', 5, 150, 1).name('Top Conv h').onChange(scheduleSync),
  fBC.add(params, 'hole_T', 10, 60, 1).name('Coolant T (°C)').onChange(scheduleSync),
  fBC.add(params, 'hole_h', 10, 600, 5).name('Bore Conv h').onChange(scheduleSync)
);

const fLoop = gui.addFolder('Closed Loop & Display');
guiControllers.push(
  fLoop.add(params, 'target_T', 45, 160, 0.5).name('Target T (°C)'),
  fLoop.add(params, 'shading', ['Thermal Field', 'CAD Clay']).name('3D Shading').onChange(scheduleSync),
  fLoop.add(params, 'wireframe').name('Wireframe / Mesh').onChange(() => {
    document.getElementById('btn-wire').classList.toggle('active', params.wireframe);
    runCoupledStep();
  }),
  fLoop.add(params, 'optimizeLoop').name('▶ Run Closed-Loop Optimize'),
  fLoop.add(params, 'resetDefaults').name('↺ Reset Parameters')
);

const fExp = gui.addFolder('Data Export');
fExp.add(params, 'exportStep').name('Export AP214 STEP');
fExp.add(params, 'exportStl').name('Export Binary STL');
fExp.add(params, 'exportVtp').name('Export FEM VTP');
fExp.close();

function resetAllParams() {
  Object.assign(params, {
    modelPreset: 'Cooling Plate (Rect + Bore)',
    W: 90, H: 60, outer_r: 30, thickness: 12, hole_r: 9.0,
    k_cond: 15.0, base_T: 180, top_h: 18, hole_T: 25, hole_h: 45,
    shading: 'Thermal Field', wireframe: false, target_T: 82,
  });
  guiControllers.forEach((c) => c.updateDisplay());
  document.getElementById('btn-wire').classList.remove('active');
  runCoupledStep();
}

function resizeViewports() {
  if (viewState.show3D) vp3D.resize();
  if (viewState.show2D) vp2D.render(lastFem, lastCdmlGeom, params);
}

function syncViewPanes() {
  pane3D.classList.toggle('hidden', !viewState.show3D);
  pane2D.classList.toggle('hidden', !viewState.show2D);
  pane2D.classList.toggle('split-border', viewState.show3D && viewState.show2D);
  const b3 = document.getElementById('btn-view-3d');
  const b2 = document.getElementById('btn-view-2d');
  b3.classList.toggle('active', viewState.show3D);
  b2.classList.toggle('active', viewState.show2D);
  b3.setAttribute('aria-pressed', String(viewState.show3D));
  b2.setAttribute('aria-pressed', String(viewState.show2D));
  resizeViewports();
}

document.getElementById('btn-view-3d').addEventListener('click', () => {
  if (viewState.show3D && !viewState.show2D) return;
  viewState.show3D = !viewState.show3D;
  syncViewPanes();
});
document.getElementById('btn-view-2d').addEventListener('click', () => {
  if (viewState.show2D && !viewState.show3D) return;
  viewState.show2D = !viewState.show2D;
  syncViewPanes();
});
document.getElementById('btn-fit').addEventListener('click', () => vp3D.fitCamera(params.thickness));
document.getElementById('btn-wire').addEventListener('click', (e) => {
  params.wireframe = !params.wireframe;
  e.currentTarget.classList.toggle('active', params.wireframe);
  e.currentTarget.setAttribute('aria-pressed', String(params.wireframe));
  guiControllers.forEach((c) => c.updateDisplay());
  runCoupledStep();
});
document.getElementById('btn-gui').addEventListener('click', (e) => {
  const hidden = gui.domElement.classList.toggle('hidden-gui');
  e.currentTarget.classList.toggle('active', !hidden);
  e.currentTarget.setAttribute('aria-pressed', String(!hidden));
});

const infoDialog = document.getElementById('info-dialog');
document.getElementById('btn-info').addEventListener('click', () => infoDialog.showModal());
document.getElementById('btn-close-info').addEventListener('click', () => infoDialog.close());
infoDialog.addEventListener('click', (e) => {
  if (e.target === infoDialog) infoDialog.close();
});
window.addEventListener('resize', resizeViewports);

// Publication Snapshot Mode (?figure=true per DESIGN.md §5.7) & Embed Mode (?embed=true per §5.8)
const urlParams = new URLSearchParams(window.location.search);
if (urlParams.get('figure') === 'true' || urlParams.get('figure') === '1') {
  document.documentElement.setAttribute('data-theme', 'light');
  document.body.classList.add('figure-mode');
}
if (urlParams.get('view') === 'split') {
  viewState.show3D = true;
  viewState.show2D = true;
} else if (urlParams.get('view') === '2d') {
  viewState.show3D = false;
  viewState.show2D = true;
}

function animate() {
  requestAnimationFrame(animate);
  if (viewState.show3D) vp3D.renderFrame();
}

(async () => {
  syncViewPanes();
  animate();
  try {
    cad = await OpenCadBridge.create();
    runCoupledStep();
  } catch (err) {
    console.error(err);
    setTelemetryLoop('err', err.message || String(err));
  }
})();

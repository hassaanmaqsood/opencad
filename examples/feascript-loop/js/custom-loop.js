/**
 * @module custom-loop
 * Drop-in runner for FEAScript users to couple custom OpenCAD CDML models with
 * custom FEAScript PDE configurations, boundary conditions, 0x1F0000 3D field
 * injection, and multi-step parameter optimization loops.
 */

import { FEAScriptModel, evaluateSolution } from 'feascript';
import { OpenCadBridge } from './opencad-bridge.js';
import { cdmlToFEAScriptGeometry } from './cdml-to-feascript.js';

/**
 * Extracts all <probe id="..."> identifiers from a CDML XML string.
 * @param {string} xml
 * @returns {string[]}
 */
export function extractCdmlProbeIds(xml) {
  const ids = [];
  for (const m of xml.matchAll(/<probe\s+[^>]*id="([^"]+)"/g)) {
    if (!ids.includes(m[1])) ids.push(m[1]);
  }
  return ids;
}

/**
 * Samples boundary wall points from converted CDML hole and outer wires so
 * 3D voxel nodes outside the 2D FEM mesh receive nearest-wall field values.
 *
 * @param {FEAScriptModel} model
 * @param {Object} result
 * @param {{ shape: Object, holes: Array }} geometry
 * @returns {{ wallSamples: Array<{x: number, y: number, val: number}>, holeMean: number, minVal: number, maxVal: number }}
 */
export function sampleSolutionWallAndBounds(model, result, geometry) {
  let minVal = Infinity;
  let maxVal = -Infinity;
  for (const v of result.solutionVector) {
    if (v < minVal) minVal = v;
    if (v > maxVal) maxVal = v;
  }

  // Sample outer wire slightly inward (-1.5e-4 m) and hole wires slightly outward (+1.5e-4 m)
  const queryPts = [];
  const sampleWireSlightlyInsideDomain = (pts, sign) => {
    if (!pts || pts.length === 0) return;
    let cx = 0;
    let cy = 0;
    for (const p of pts) {
      cx += p[0];
      cy += p[1];
    }
    cx /= pts.length;
    cy /= pts.length;
    for (const p of pts) {
      const dx = p[0] - cx;
      const dy = p[1] - cy;
      const len = Math.hypot(dx, dy) || 1;
      queryPts.push([p[0] + sign * (dx / len) * 1.5e-4, p[1] + sign * (dy / len) * 1.5e-4]);
    }
  };

  for (const h of geometry.holes || []) {
    sampleWireSlightlyInsideDomain(h.points, +1);
  }
  const holeSampleCount = queryPts.length;
  if (geometry.shape && geometry.shape.points) {
    sampleWireSlightlyInsideDomain(geometry.shape.points, -1);
  }

  const rawVals = queryPts.length > 0 ? evaluateSolution(model, result, queryPts) : [];
  const wallSamples = queryPts
    .map((pt, i) => ({ x: pt[0], y: pt[1], val: rawVals[i], isHole: i < holeSampleCount }))
    .filter((s) => Number.isFinite(s.val));

  const holeOnly = wallSamples.filter((s) => s.isHole);
  const holeMean = holeOnly.length > 0
    ? holeOnly.reduce((acc, s) => acc + s.val, 0) / holeOnly.length
    : (minVal + maxVal) * 0.5;

  return { wallSamples, holeMean, minVal, maxVal };
}

/**
 * Builds a 3D Float32Array voxel grid over the OpenCAD solid bounding box from
 * any 2D FEAScript solution, extrapolating hole/exterior voxels from the nearest
 * sampled boundary point.
 *
 * @param {FEAScriptModel} model
 * @param {Object} result
 * @param {number[]} bbox - [minX, minY, minZ, maxX, maxY, maxZ] in mm
 * @param {{ wallSamples: Array<{x: number, y: number, val: number}>, holeMean: number }} stats
 * @param {[number, number, number]} [gridSize=[48, 36, 4]]
 * @param {number} [unitScale=0.001]
 * @returns {Float32Array}
 */
export function buildCustomVoxelFieldGrid(
  model,
  result,
  bbox,
  stats,
  gridSize = [48, 36, 4],
  unitScale = 0.001
) {
  const [gx, gy, gz] = gridSize;
  const [minX, minY, , maxX, maxY] = bbox;
  const pts = [];
  for (let iy = 0; iy < gy; iy++) {
    const y = minY + ((maxY - minY) * iy) / Math.max(1, gy - 1);
    for (let ix = 0; ix < gx; ix++) {
      const x = minX + ((maxX - minX) * ix) / Math.max(1, gx - 1);
      pts.push([x * unitScale, y * unitScale]);
    }
  }

  const sampled = evaluateSolution(model, result, pts);
  const field = new Float32Array(gx * gy * gz);
  const wall = stats.wallSamples || [];

  for (let i = 0; i < gx * gy; i++) {
    let val = sampled[i];
    if (!Number.isFinite(val)) {
      if (wall.length > 0) {
        const [px, py] = pts[i];
        let bestD = Infinity;
        let bestV = stats.holeMean;
        for (let k = 0; k < wall.length; k++) {
          const dx = px - wall[k].x;
          const dy = py - wall[k].y;
          const d2 = dx * dx + dy * dy;
          if (d2 < bestD) {
            bestD = d2;
            bestV = wall[k].val;
          }
        }
        val = bestV;
      } else {
        val = stats.holeMean;
      }
    }
    for (let iz = 0; iz < gz; iz++) {
      field[iz * gy * gx + i] = val;
    }
  }

  return field;
}

/**
 * Executes a single coupled OpenCAD <-> FEAScript step with user-supplied CDML
 * and custom FEAScript model settings.
 *
 * @param {Object} config
 * @param {OpenCadBridge} [config.cad] - Existing OpenCadBridge instance (created if omitted)
 * @param {string | ((params: Object) => string)} config.cdml - CDML v1.0 XML string or builder function
 * @param {Object} [config.params={}] - Parameter dictionary passed to builders and callbacks
 * @param {string} [config.solverType='heatConduction'] - FEAScript physics mode
 * @param {Object | ((params: Object, cdmlGeom: Object) => Object)} [config.solverConfig] - FEAScript setModelConfig options
 * @param {Object | ((params: Object, cdmlGeom: Object) => Object)} [config.meshConfig] - FEAScript setMeshConfig options
 * @param {Record<string, Object> | ((params: Object, cdmlGeom: Object) => Record<string, Object>)} [config.boundaryConditions] - Map of CDML curve IDs to FEAScript boundary condition objects
 * @param {(model: FEAScriptModel, params: Object, cdmlGeom: Object) => void} [config.configureModel] - Optional hook for custom FEAScriptModel configuration
 * @param {Object} [config.converterOptions] - Options for cdmlToFEAScriptGeometry (holeSamples, nurbsSamples, unitScale)
 * @param {boolean} [config.injectField=true] - Whether to write the solved 2D field back to OpenCAD 0x1F0000 and re-evaluate Pass 2
 * @param {[number, number, number]} [config.gridSize=[48, 36, 4]] - 3D voxel field grid dimensions
 * @param {string[]} [config.probeIds] - Explicit CDML <probe> IDs to read (auto-detected if omitted)
 */
export async function runCustomCoupledStep(config) {
  const cad = config.cad || (await OpenCadBridge.create(config.bridgeOptions));
  const params = config.params || {};
  const xml = typeof config.cdml === 'function' ? config.cdml(params) : String(config.cdml);
  const probeIds = config.probeIds || extractCdmlProbeIds(xml);

  // Pass 1: Evaluate CDML in OpenCAD & convert <sketch> wires to FEAScript domain
  const pass1 = cad.evalCdml(xml, probeIds);
  const cdmlGeom = cdmlToFEAScriptGeometry(xml, config.converterOptions);

  // Pass 2: Configure & solve FEAScript model
  const model = new FEAScriptModel();
  const solverType = config.solverType || 'heatConduction';
  const solverCfg = typeof config.solverConfig === 'function'
    ? config.solverConfig(params, cdmlGeom)
    : (config.solverConfig || {
        solver: { method: 'lusolve' },
        coefficientFunctions: { thermalConductivity: params.k ?? 15.0, heatSource: params.q ?? 0.0 },
      });
  model.setModelConfig(solverType, solverCfg);
  model.setGeometry(cdmlGeom.geometry);

  const [minX, minY, , maxX, maxY] = pass1.bbox;
  const spanM = Math.max(1e-3, Math.min(maxX - minX, maxY - minY) * 0.001);
  const meshCfg = typeof config.meshConfig === 'function'
    ? config.meshConfig(params, cdmlGeom)
    : (config.meshConfig || {
        elements: 'triangles',
        elementOrder: 'linear',
        size: Math.max(0.002, spanM / 18),
        minAngle: 25,
      });
  model.setMeshConfig(meshCfg);

  const bcs = typeof config.boundaryConditions === 'function'
    ? config.boundaryConditions(params, cdmlGeom)
    : (config.boundaryConditions || {});
  for (const [boundaryName, bcSpec] of Object.entries(bcs)) {
    if (bcSpec) {
      model.addBoundaryCondition(boundaryName, bcSpec);
    }
  }

  if (typeof config.configureModel === 'function') {
    config.configureModel(model, params, cdmlGeom);
  }

  const result = model.solve();
  const mesh = model.getMesh();
  const stats = sampleSolutionWallAndBounds(model, result, cdmlGeom.geometry);

  // Pass 3: Inject 3D voxel field into OpenCAD 0x1F0000 and re-evaluate probes/geometry
  let pass2 = pass1;
  let fieldGrid = null;
  if (config.injectField !== false) {
    const unitScale = config.converterOptions?.unitScale ?? 0.001;
    fieldGrid = buildCustomVoxelFieldGrid(model, result, pass1.bbox, stats, config.gridSize, unitScale);
    cad.writeFieldBuffer(fieldGrid);
    pass2 = cad.evalCdml(xml, probeIds);
  }

  return {
    cad,
    xml,
    params: { ...params },
    cdmlGeom,
    pass1,
    pass2,
     probes: pass2.probes,
    fem: {
      model,
      result,
      mesh,
      minVal: stats.minVal,
      maxVal: stats.maxVal,
      holeMean: stats.holeMean,
      wallSamples: stats.wallSamples,
      evaluate: (ptsMeters) => evaluateSolution(model, result, ptsMeters),
    },
    fieldGrid,
  };
}

/**
 * Runs a multi-iteration custom OpenCAD <-> FEAScript closed-loop optimization or parameter study.
 *
 * @param {Object} config - Same options as runCustomCoupledStep plus loop controls:
 * @param {number} [config.maxIterations=8] - Maximum number of coupled loop iterations
 * @param {(state: Object, iteration: number, history: Object[]) => ({ done?: boolean, nextParams?: Object } | Promise<{ done?: boolean, nextParams?: Object }>)} [config.step]
 *   Callback invoked after each coupled solve. Return `{ done: true }` when converged, or
 *   `{ done: false, nextParams: { ... } }` to continue with updated parameters.
 */
export async function runCustomFEAScriptLoop(config) {
  const cad = config.cad || (await OpenCadBridge.create(config.bridgeOptions));
  const maxIterations = config.maxIterations ?? (typeof config.step === 'function' ? 8 : 1);
  let currentParams = { ...(config.params || {}) };
  const history = [];
  let lastState = null;

  for (let iter = 0; iter < maxIterations; iter++) {
    lastState = await runCustomCoupledStep({
      ...config,
      cad,
      params: currentParams,
    });
    history.push(lastState);

    if (typeof config.step !== 'function') {
      break;
    }
    const decision = await config.step(lastState, iter, history);
    if (!decision || decision.done) {
      break;
    }
    if (decision.nextParams) {
      currentParams = { ...currentParams, ...decision.nextParams };
    }
  }

  return {
    cad,
    iterations: history.length,
    final: lastState,
    history,
  };
}

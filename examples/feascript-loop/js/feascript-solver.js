/**
 * @module feascript-solver
 * Drop-in 2D steady heat-conduction wrapper for FEAScript 0.4.1 and nearest-wall
 * 3D voxel field generator for OpenCAD's 0x1F0000 Field Buffer.
 */

import { FEAScriptModel, evaluateSolution } from 'feascript';

/**
 * Solves 2D steady heat conduction on a converted CDML geometry in FEAScript.
 * @param {{ geometry: { shape: Object, holes: Array } }} cdmlGeom
 * @param {Object} params
 */
export function solveThermal2D(cdmlGeom, params) {
  const isDisk = params.modelPreset === 'Annular Disk (Benchmark)';
  const model = new FEAScriptModel();

  model.setModelConfig('heatConduction', {
    solver: { method: 'lusolve' },
    coefficientFunctions: { thermalConductivity: params.k_cond, heatSource: 0.0 },
  });
  model.setGeometry(cdmlGeom.geometry);

  const spanM = isDisk
    ? (params.outer_r * 2) / 1000
    : Math.min(params.W, params.H) / 1000;
  model.setMeshConfig({
    elements: 'triangles',
    elementOrder: 'linear',
    size: Math.max(0.0022, spanM / 18),
    minAngle: 25,
  });

  if (isDisk) {
    model.addBoundaryCondition('rim',  { type: 'constantTemperature', temperature: params.base_T });
    model.addBoundaryCondition('bore', { type: 'convection', h: params.hole_h, ambientTemperature: params.hole_T });
  } else {
    model.addBoundaryCondition('bottom', { type: 'constantTemperature', temperature: params.base_T });
    model.addBoundaryCondition('top',    { type: 'convection', h: params.top_h, ambientTemperature: 25.0 });
    model.addBoundaryCondition('bore',   { type: 'convection', h: params.hole_h * 12.0, ambientTemperature: params.hole_T });
    model.addBoundaryCondition('left',   { type: 'convection', h: 12.0, ambientTemperature: 25.0 });
    model.addBoundaryCondition('right',  { type: 'convection', h: 12.0, ambientTemperature: 25.0 });
  }

  const result = model.solve();
  const mesh = model.getMesh();

  let minT = Infinity;
  let maxT = -Infinity;
  for (const v of result.solutionVector) {
    if (v < minT) minT = v;
    if (v > maxT) maxT = v;
  }

  // Sample bore wall points for nearest-boundary-point voxel interpolation
  const R = params.hole_r / 1000;
  const boreWallPts = Array.from({ length: 64 }, (_, i) => {
    const a = (2 * Math.PI * i) / 64;
    return [(R + 0.00015) * Math.cos(a), (R + 0.00015) * Math.sin(a)];
  });
  const boreWallVals = evaluateSolution(model, result, boreWallPts);
  const boreSamples = boreWallPts
    .map((pt, i) => ({ x: pt[0], y: pt[1], t: boreWallVals[i] }))
    .filter((s) => Number.isFinite(s.t));
  const boreMeanT = boreSamples.length
    ? boreSamples.reduce((acc, s) => acc + s.t, 0) / boreSamples.length
    : params.hole_T;

  let edgeMeanT = boreMeanT;
  if (!isDisk) {
    const W = params.W / 1000;
    const H = params.H / 1000;
    const topSamples = Array.from({ length: 25 }, (_, i) => [
      -W / 2 + ((i + 0.5) / 25) * W,
      H / 2 - 1e-5,
    ]);
    const topVals = evaluateSolution(model, result, topSamples).filter(Number.isFinite);
    edgeMeanT = topVals.length ? topVals.reduce((a, b) => a + b, 0) / topVals.length : maxT;
  }

  return { model, result, mesh, minT, maxT, edgeMeanT, boreMeanT, boreSamples };
}

/**
 * Samples a 2D FEAScript solution onto a 3D Float32Array voxel grid for OpenCAD's 0x1F0000 buffer.
 * Voxels inside the cooling bore (where evaluateSolution returns NaN) receive the temperature
 * of the nearest point on the bore wall so OpenCAD's trilinear bore <probe> matches the wall.
 *
 * @param {Object} fem - Output from solveThermal2D()
 * @param {number[]} bbox - [minX, minY, minZ, maxX, maxY, maxZ] in mm
 * @param {Object} params
 * @returns {Float32Array}
 */
export function buildNearestWallFieldGrid(fem, bbox, params) {
  const isDisk = params.modelPreset === 'Annular Disk (Benchmark)';
  const gx = 48;
  const gy = isDisk ? 48 : 36;
  const gz = 4;
  const [minX, minY, , maxX, maxY] = bbox;

  const pts = [];
  for (let iy = 0; iy < gy; iy++) {
    const y = minY + ((maxY - minY) * iy) / (gy - 1);
    for (let ix = 0; ix < gx; ix++) {
      const x = minX + ((maxX - minX) * ix) / (gx - 1);
      pts.push([x / 1000, y / 1000]);
    }
  }

  const sampled = evaluateSolution(fem.model, fem.result, pts);
  const field = new Float32Array(gx * gy * gz);
  const wall = fem.boreSamples;
  const rimT = params.base_T;
  const outerRm = (params.outer_r || 30) / 1000;

  for (let i = 0; i < gx * gy; i++) {
    let val = sampled[i];
    if (!Number.isFinite(val)) {
      const [px, py] = pts[i];
      const r = Math.hypot(px, py);
      if (isDisk && r > outerRm * 0.92) {
        val = rimT;
      } else if (wall.length > 0) {
        let bestD = Infinity;
        let bestT = fem.boreMeanT;
        for (let k = 0; k < wall.length; k++) {
          const dx = px - wall[k].x;
          const dy = py - wall[k].y;
          const d2 = dx * dx + dy * dy;
          if (d2 < bestD) {
            bestD = d2;
            bestT = wall[k].t;
          }
        }
        val = bestT;
      } else {
        val = fem.boreMeanT;
      }
    }
    for (let iz = 0; iz < gz; iz++) {
      field[iz * gy * gx + i] = val;
    }
  }

  return field;
}

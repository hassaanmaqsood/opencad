/**
 * @module viewports
 * Reusable 3D (Three.js B-Rep + thermal field overlay) and 2D (FEAScript triangular
 * contour canvas + interactive hover probe) viewports.
 */

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { evaluateSolution } from 'feascript';

/**
 * Exact 13-stop Matplotlib `plasma` colormap LUT (sampled from matplotlib.cm.plasma).
 * Used identically across 2D Canvas, 3D WebGL vertex colors, and CSS colorbar.
 */
const PLASMA_STOPS = [
  [13, 8, 135],    // 0.000 #0d0887
  [53, 4, 152],    // 0.083 #350498
  [84, 2, 163],    // 0.167 #5402a3
  [114, 1, 168],   // 0.250 #7201a8
  [139, 10, 165],  // 0.333 #8b0aa5
  [163, 30, 154],  // 0.417 #a31e9a
  [185, 50, 137],  // 0.500 #b93289
  [204, 71, 120],  // 0.583 #cc4778
  [219, 92, 104],  // 0.667 #db5c68
  [233, 114, 87],  // 0.750 #e97257
  [244, 136, 73],  // 0.833 #f48849
  [251, 162, 56],  // 0.917 #fba238
  [254, 190, 42],  // 0.960 #febe2a
  [240, 249, 33],  // 1.000 #f0f921
];

/**
 * Matplotlib `plasma` colormap evaluator returning sRGB [0..255].
 * @param {number} tNorm - Normalized scalar in [0, 1]
 * @returns {[number, number, number]} sRGB tuple in 0..255
 */
export function thermalRGB(tNorm) {
  const t = Math.max(0, Math.min(1, tNorm));
  const s = t * (PLASMA_STOPS.length - 1);
  const i = Math.min(PLASMA_STOPS.length - 2, Math.floor(s));
  const f = s - i;
  return [
    Math.round(PLASMA_STOPS[i][0] + (PLASMA_STOPS[i + 1][0] - PLASMA_STOPS[i][0]) * f),
    Math.round(PLASMA_STOPS[i][1] + (PLASMA_STOPS[i + 1][1] - PLASMA_STOPS[i][1]) * f),
    Math.round(PLASMA_STOPS[i][2] + (PLASMA_STOPS[i + 1][2] - PLASMA_STOPS[i][2]) * f),
  ];
}

/**
 * Converts a normalized sRGB channel [0..1] to Linear-sRGB [0..1] so Three.js
 * SRGBColorSpace output matches 2D HTML5 Canvas sRGB colors pixel-for-pixel.
 * @param {number} c - sRGB value in [0, 1]
 * @returns {number} Linear-sRGB value in [0, 1]
 */
function srgbToLinear(c) {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

export class Thermal3DViewport {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {HTMLElement} container
   */
  constructor(canvas, container) {
    this.canvas = canvas;
    this.container = container;
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setClearColor(0xFFFFFF, 1);

    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(40, 1, 0.5, 2000);
    this.camera.up.set(0, 0, 1);

    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;

    this.scene.add(new THREE.AmbientLight(0xffffff, 0.75));
    const keyLight = new THREE.DirectionalLight(0xffffff, 0.85);
    keyLight.position.set(120, -90, 160);
    this.scene.add(keyLight);
    const fillLight = new THREE.DirectionalLight(0xe5e5e5, 0.45);
    fillLight.position.set(-100, 100, -80);
    this.scene.add(fillLight);

    const grid = new THREE.GridHelper(180, 18, 0xD4D4D8, 0xECECEF);
    grid.rotation.x = Math.PI / 2;
    grid.position.z = -0.2;
    this.scene.add(grid);

    this.cadMeshObj = null;
    this.cadWireObj = null;
    this.fitCamera(12);
  }

  fitCamera(thickness = 12) {
    this.camera.position.set(112, -108, 96);
    this.controls.target.set(0, 0, thickness * 0.4);
    this.controls.update();
  }

  resize() {
    const w = this.container.clientWidth;
    const h = this.container.clientHeight;
    if (w > 0 && h > 0) {
      this.renderer.setSize(w, h, false);
      this.camera.aspect = w / h;
      this.camera.updateProjectionMatrix();
    }
  }

  renderFrame() {
    this.controls.update();
    this.renderer.render(this.scene, this.camera);
  }

  /**
   * Updates the 3D B-Rep mesh and projects FEAScript's 2D thermal field onto every vertex.
   */
  updateMesh(cadData, fem, params) {
    if (this.cadMeshObj) {
      this.scene.remove(this.cadMeshObj);
      this.cadMeshObj.geometry.dispose();
      this.cadMeshObj.material.dispose();
    }
    if (this.cadWireObj) {
      this.scene.remove(this.cadWireObj);
      this.cadWireObj.geometry.dispose();
      this.cadWireObj.material.dispose();
    }

    // Adaptive subdivision down to maxEdge <= 3.5 mm eliminates color streaking around the bore
    const outPos = [];
    const outNrm = [];
    const pushTri = (ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz, depth) => {
      const maxE = Math.max(
        Math.hypot(bx - ax, by - ay, bz - az),
        Math.hypot(cx - bx, cy - by, cz - bz),
        Math.hypot(ax - cx, ay - cy, az - cz)
      );
      if (depth < 5 && maxE > 3.5) {
        const mabx = (ax + bx) * 0.5, maby = (ay + by) * 0.5, mabz = (az + bz) * 0.5;
        const mbcx = (bx + cx) * 0.5, mbcy = (by + cy) * 0.5, mbcz = (bz + cz) * 0.5;
        const mcax = (cx + ax) * 0.5, mcay = (cy + ay) * 0.5, mcaz = (cz + az) * 0.5;
        pushTri(ax, ay, az, mabx, maby, mabz, mcax, mcay, mcaz, nx, ny, nz, depth + 1);
        pushTri(mabx, maby, mabz, bx, by, bz, mbcx, mbcy, mbcz, nx, ny, nz, depth + 1);
        pushTri(mcax, mcay, mcaz, mbcx, mbcy, mbcz, cx, cy, cz, nx, ny, nz, depth + 1);
        pushTri(mabx, maby, mabz, mbcx, mbcy, mbcz, mcax, mcay, mcaz, nx, ny, nz, depth + 1);
        return;
      }
      outPos.push(ax, ay, az, bx, by, bz, cx, cy, cz);
      outNrm.push(nx, ny, nz, nx, ny, nz, nx, ny, nz);
    };

    const pos = cadData.positions;
    const idx = cadData.indices;
    for (let t = 0; t < cadData.triangleCount; t++) {
      const i0 = idx[t * 3] * 3, i1 = idx[t * 3 + 1] * 3, i2 = idx[t * 3 + 2] * 3;
      const ax = pos[i0], ay = pos[i0 + 1], az = pos[i0 + 2];
      const bx = pos[i1], by = pos[i1 + 1], bz = pos[i1 + 2];
      const cx = pos[i2], cy = pos[i2 + 1], cz = pos[i2 + 2];
      const nx = (by - ay) * (cz - az) - (bz - az) * (cy - ay);
      const ny = (bz - az) * (cx - ax) - (bx - ax) * (cz - az);
      const nz = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
      const nl = Math.hypot(nx, ny, nz) || 1;
      pushTri(ax, ay, az, bx, by, bz, cx, cy, cz, nx / nl, ny / nl, nz / nl, 0);
    }

    const geom = new THREE.BufferGeometry();
    const dispPos = new Float32Array(outPos);
    const dispNrm = new Float32Array(outNrm);
    geom.setAttribute('position', new THREE.BufferAttribute(dispPos, 3));
    geom.setAttribute('normal', new THREE.BufferAttribute(dispNrm, 3));

    const vCount = dispPos.length / 3;
    const qPts = Array.from({ length: vCount }, (_, i) => [dispPos[i * 3] / 1000, dispPos[i * 3 + 1] / 1000]);
    const temps = evaluateSolution(fem.model, fem.result, qPts);
    const colors = new Float32Array(vCount * 3);
    const span = Math.max(1e-6, fem.maxT - fem.minT);
    const wall = fem.boreSamples;
    const isDisk = params.modelPreset === 'Annular Disk (Benchmark)';

    for (let i = 0; i < vCount; i++) {
      let tVal = temps[i];
      if (!Number.isFinite(tVal)) {
        const [px, py] = qPts[i];
        if (isDisk && Math.hypot(px, py) > (params.outer_r / 1000) * 0.9) {
          tVal = params.base_T;
        } else if (wall.length > 0) {
          let bestD = Infinity, bestT = fem.boreMeanT;
          for (let k = 0; k < wall.length; k++) {
            const dx = px - wall[k].x, dy = py - wall[k].y;
            const d2 = dx * dx + dy * dy;
            if (d2 < bestD) { bestD = d2; bestT = wall[k].t; }
          }
          tVal = bestT;
        } else {
          tVal = fem.boreMeanT;
        }
      }
      const [r, g, b] = thermalRGB((tVal - fem.minT) / span);
      // Subtle normal-based depth cue (1.00 on top face so 3D top face matches 2D canvas 100%, 0.90 on vertical walls)
      const nz = Math.abs(dispNrm[i * 3 + 2]);
      const shade = 0.90 + 0.10 * nz;
      colors[i * 3] = srgbToLinear((r / 255) * shade);
      colors[i * 3 + 1] = srgbToLinear((g / 255) * shade);
      colors[i * 3 + 2] = srgbToLinear((b / 255) * shade);
    }
    geom.setAttribute('color', new THREE.BufferAttribute(colors, 3));

    const useThermal = params.shading === 'Thermal Field';
    const mat = useThermal
      ? new THREE.MeshBasicMaterial({
          vertexColors: true,
          polygonOffset: true,
          polygonOffsetFactor: 1,
        })
      : new THREE.MeshStandardMaterial({
          color: 0xd4d4d8,
          roughness: 0.42,
          metalness: 0.08,
          polygonOffset: true,
          polygonOffsetFactor: 1,
        });
    this.cadMeshObj = new THREE.Mesh(geom, mat);
    this.scene.add(this.cadMeshObj);

    if (params.wireframe) {
      this.cadWireObj = new THREE.Mesh(geom, new THREE.MeshBasicMaterial({
        color: 0x18181b,
        wireframe: true,
        transparent: true,
        opacity: 0.18,
      }));
      this.scene.add(this.cadWireObj);
    }
  }
}

export class Fem2DViewport {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {HTMLElement} container
   * @param {HTMLElement} hoverLabelEl
   */
  constructor(canvas, container, hoverLabelEl) {
    this.canvas = canvas;
    this.container = container;
    this.hoverLabelEl = hoverLabelEl;
    this.ctx = canvas.getContext('2d');
    this.xform = { scale: 1, ox: 0, oy: 0 };
    this.lastFem = null;
    this.lastGeomData = null;
    this.lastParams = null;

    this.canvas.addEventListener('pointermove', (ev) => this.onPointerMove(ev));
  }

  onPointerMove(ev) {
    if (!this.lastFem || !this.lastParams) return;
    const rect = this.canvas.getBoundingClientRect();
    const x = (ev.clientX - rect.left - this.xform.ox) / this.xform.scale;
    const y = (this.xform.oy - (ev.clientY - rect.top)) / this.xform.scale;
    const val = evaluateSolution(this.lastFem.model, this.lastFem.result, [[x, y]])[0];
    this.hoverLabelEl.textContent = Number.isFinite(val)
      ? `(${(x * 1000).toFixed(1)}, ${(y * 1000).toFixed(1)} mm): ${val.toFixed(2)} °C`
      : `Outside mesh / cooling bore (T_∞ = ${this.lastParams.hole_T} °C)`;
  }

  render(fem, geomData, params) {
    if (fem) this.lastFem = fem;
    if (geomData) this.lastGeomData = geomData;
    if (params) this.lastParams = params;
    if (!this.lastFem || !this.lastGeomData || !this.lastParams) return;

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const cw = this.container.clientWidth;
    const ch = this.container.clientHeight;
    if (cw === 0 || ch === 0) return;

    this.canvas.width = Math.round(cw * dpr);
    this.canvas.height = Math.round(ch * dpr);
    const ctx = this.ctx;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(0, 0, cw, ch);

    const { result, mesh, minT, maxT } = this.lastFem;
    const p = this.lastParams;
    const xs = result.nodesCoordinates.nodesXCoordinates;
    const ys = result.nodesCoordinates.nodesYCoordinates;
    const sol = result.solutionVector;
    const elems = mesh.nodalNumbering;

    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (let i = 0; i < xs.length; i++) {
      if (xs[i] < minX) minX = xs[i];
      if (xs[i] > maxX) maxX = xs[i];
      if (ys[i] < minY) minY = ys[i];
      if (ys[i] > maxY) maxY = ys[i];
    }
    const domW = Math.max(1e-6, maxX - minX);
    const domH = Math.max(1e-6, maxY - minY);
    const scale = Math.min((cw - 120) / domW, (ch - 140) / domH);
    const ox = cw / 2 - ((minX + maxX) * 0.5) * scale;
    const oy = ch / 2 + ((minY + maxY) * 0.5) * scale - 10;
    this.xform = { scale, ox, oy };
    const toS = (x, y) => [ox + x * scale, oy - y * scale];

    const span = Math.max(1e-6, maxT - minT);
    for (const tri of elems) {
      const i0 = tri[0] - 1, i1 = tri[1] - 1, i2 = tri[2] - 1;
      const [x0, y0] = toS(xs[i0], ys[i0]);
      const [x1, y1] = toS(xs[i1], ys[i1]);
      const [x2, y2] = toS(xs[i2], ys[i2]);
      const [r, g, b] = thermalRGB((((sol[i0] + sol[i1] + sol[i2]) / 3) - minT) / span);
      ctx.fillStyle = `rgb(${r},${g},${b})`;
      ctx.beginPath();
      ctx.moveTo(x0, y0);
      ctx.lineTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.closePath();
      ctx.fill();
      if (p.wireframe) {
        ctx.strokeStyle = 'rgba(24, 24, 27, 0.22)';
        ctx.lineWidth = 0.65;
        ctx.stroke();
      }
    }

    const { shape, holes } = this.lastGeomData.geometry;
    ctx.strokeStyle = '#18181B';
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    const [sx, sy] = toS(shape.start[0], shape.start[1]);
    ctx.moveTo(sx, sy);
    for (const b of shape.boundaries) {
      const pt = b.to || shape.start;
      const [px, py] = toS(pt[0], pt[1]);
      ctx.lineTo(px, py);
    }
    ctx.closePath();
    ctx.stroke();

    for (const h of holes) {
      ctx.beginPath();
      h.points.forEach((pt, idx) => {
        const [px, py] = toS(pt[0], pt[1]);
        if (idx === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      });
      ctx.closePath();
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();
      ctx.strokeStyle = '#0C71E4';
      ctx.lineWidth = 1.6;
      ctx.stroke();
    }

    const [cxS, cyS] = toS(0, 0);
    const rPx = (p.hole_r / 1000) * scale;
    ctx.font = '500 11px "IBM Plex Mono", monospace';
    ctx.textAlign = 'center';
    if (p.modelPreset === 'Annular Disk (Benchmark)') {
      ctx.fillStyle = '#0A50A8';
      ctx.fillText(`rim = ${p.base_T}°C`, cxS, oy - maxY * scale - 10);
    } else {
      ctx.fillStyle = '#0A50A8';
      ctx.fillText(`bottom = ${p.base_T}°C`, cxS, oy - minY * scale + 18);
      ctx.fillStyle = '#52525B';
      ctx.fillText(`top_h = ${p.top_h} W/m²K`, cxS, oy - maxY * scale - 10);
    }
    if (rPx >= 24) {
      ctx.font = rPx >= 36 ? '500 11px "IBM Plex Mono", monospace' : '400 10px "IBM Plex Mono", monospace';
      ctx.fillStyle = '#0A50A8';
      ctx.fillText(`T_∞=${p.hole_T}°C`, cxS, cyS + 3);
    }
  }
}

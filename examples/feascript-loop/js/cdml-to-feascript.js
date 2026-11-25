/**
 * @module cdml-to-feascript
 * Drop-in converter that extracts a 2D planar domain ({ shape, holes }) for FEAScript
 * directly from an OpenCAD CDML v1.0 <sketch>, preserving curve IDs as boundary names.
 */

/**
 * Evaluates a scalar CDML math expression (`ref(id)`, `PI`, `cos`, `sin`, `sqrt`, `^`).
 * @param {string} expr
 * @param {Record<string, number>} env
 * @returns {number}
 */
export function evalCdmlScalar(expr, env) {
  const jsExpr = expr
    .replace(/ref\(([^)]+)\)/g, (_, id) => `(${env[id.trim()] ?? 0})`)
    .replace(/\bPI\b/g, 'Math.PI')
    .replace(/\bcos\b/g, 'Math.cos')
    .replace(/\bsin\b/g, 'Math.sin')
    .replace(/\bsqrt\b/g, 'Math.sqrt')
    .replace(/\^/g, '**');
  const keys = Object.keys(env);
  const vals = keys.map((k) => env[k]);
  return Function(...keys, `"use strict"; return (${jsExpr});`)(...vals);
}

/**
 * Converts a CDML v1.0 XML document's <sketch> into a FEAScript 2D geometry object.
 * Coordinates are converted from millimeters (CDML default) to meters (SI).
 *
 * @param {string} xmlStr - Full CDML XML document string
 * @param {Object} [options]
 * @param {number} [options.holeSamples=48] - Number of polygon vertices for parametric holes
 * @param {number} [options.outerCurveSamples=72] - Number of polygon vertices for parametric outer wires
 * @param {number} [options.unitScale=0.001] - Scale factor from CDML units to FEAScript units (mm -> m)
 * @returns {{ geometry: { shape: Object, holes: Array }, boundaryNames: string[], vars: Record<string, number> }}
 */
export function cdmlToFEAScriptGeometry(xmlStr, options = {}) {
  const holeSamples = options.holeSamples ?? 48;
  const outerCurveSamples = options.outerCurveSamples ?? 72;
  const unitScale = options.unitScale ?? 0.001;

  const doc = new DOMParser().parseFromString(xmlStr, 'application/xml');
  const env = {};

  doc.querySelectorAll('defs > var').forEach((el) => {
    env[el.getAttribute('id')] = parseFloat(el.getAttribute('value') || '0');
  });
  doc.querySelectorAll('defs > expr').forEach((el) => {
    env[el.getAttribute('id')] = evalCdmlScalar(el.getAttribute('expr') || '0', env);
  });

  const sketch = doc.querySelector('body > sketch');
  if (!sketch) {
    throw new Error('CDML document contains no <sketch> element');
  }

  const ptsMap = new Map();
  sketch.querySelectorAll('vars > point2d').forEach((pt) => {
    ptsMap.set(pt.getAttribute('id'), [
      parseFloat(pt.getAttribute('u') || '0') * unitScale,
      parseFloat(pt.getAttribute('v') || '0') * unitScale,
    ]);
  });

  const sampleParamCurve = (el, nSamples) => {
    const paramName = el.getAttribute('param') || 't';
    const [d0, d1] = (el.getAttribute('domain') || '0 1').trim().split(/\s+/).map(Number);
    const uExpr = el.getAttribute('u-expr') || '0';
    const vExpr = el.getAttribute('v-expr') || '0';
    const out = [];
    for (let i = 0; i < nSamples; i++) {
      const tVal = d0 + ((d1 - d0) * i) / nSamples;
      const localEnv = { ...env, [paramName]: tVal };
      out.push([
        evalCdmlScalar(uExpr, localEnv) * unitScale,
        evalCdmlScalar(vExpr, localEnv) * unitScale,
      ]);
    }
    return out;
  };

  let shape = null;
  const holes = [];
  const boundaryNames = [];

  sketch.querySelectorAll('wire').forEach((wire) => {
    const role = wire.getAttribute('role') || 'outer';
    const children = Array.from(wire.children);

    if (role === 'outer') {
      if (children.length === 1 && children[0].tagName === 'param-curve') {
        const pc = children[0];
        const name = pc.getAttribute('id') || 'outer';
        const ring = sampleParamCurve(pc, outerCurveSamples);
        const boundaries = [];
        for (let i = 0; i < ring.length; i++) {
          const next = ring[(i + 1) % ring.length];
          boundaries.push(i === ring.length - 1 ? { name } : { name, to: next });
        }
        shape = { start: ring[0], boundaries };
        boundaryNames.push(name);
      } else {
        let start = null;
        const boundaries = [];
        children.forEach((seg, idx) => {
          const name = seg.getAttribute('id') || `edge_${idx}`;
          boundaryNames.push(name);
          if (seg.tagName === 'curve' || seg.tagName === 'line') {
            const refs = seg.tagName === 'curve'
              ? (seg.getAttribute('ctrl') || '').trim().split(/\s+/)
              : [seg.getAttribute('p0'), seg.getAttribute('p1')];
            const pStart = ptsMap.get(refs[0]);
            const pEnd = ptsMap.get(refs[refs.length - 1]);
            if (idx === 0) start = pStart;
            boundaries.push(idx === children.length - 1 ? { name } : { name, to: pEnd });
          }
        });
        shape = { start, boundaries };
      }
    } else {
      let holePts = [];
      let holeName = wire.getAttribute('id') || 'hole';
      children.forEach((seg) => {
        if (seg.tagName === 'param-curve') {
          holeName = seg.getAttribute('id') || holeName;
          holePts = holePts.concat(sampleParamCurve(seg, holeSamples));
        } else if (seg.tagName === 'curve' || seg.tagName === 'line') {
          const refs = seg.tagName === 'curve'
            ? (seg.getAttribute('ctrl') || '').trim().split(/\s+/)
            : [seg.getAttribute('p0'), seg.getAttribute('p1')];
          holePts.push(ptsMap.get(refs[0]));
        }
      });
      if (holePts.length >= 3) {
        holes.push({ name: holeName, points: holePts });
        boundaryNames.push(holeName);
      }
    }
  });

  return { geometry: { shape, holes }, boundaryNames, vars: env };
}

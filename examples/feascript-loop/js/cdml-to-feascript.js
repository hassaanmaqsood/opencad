/**
 * @module cdml-to-feascript
 * Drop-in converter that extracts a 2D planar domain ({ shape, holes }) for FEAScript
 * directly from an OpenCAD CDML v1.0 <sketch>, preserving curve IDs as boundary names.
 *
 * Implements:
 * 1. Zero-eval recursive-descent parser for CDML v1.0 scalar math expressions (CSP-safe,
 *    no Function() or eval(), rejects arbitrary JS injection).
 * 2. Exact Cox-de Boor rational B-spline (NURBS) evaluator for <curve degree="p">
 *    so degree-1 curves remain single straight segments while degree >= 2 curves
 *    (arcs, fillets, splines) are discretized into short straight segments keeping
 *    the curve ID as their FEAScript boundary name.
 */

const SAFE_MATH_FUNCS = {
  sin: Math.sin,
  cos: Math.cos,
  tan: Math.tan,
  asin: Math.asin,
  acos: Math.acos,
  atan: Math.atan,
  atan2: Math.atan2,
  sinh: Math.sinh,
  cosh: Math.cosh,
  tanh: Math.tanh,
  sqrt: Math.sqrt,
  abs: Math.abs,
  min: Math.min,
  max: Math.max,
  exp: Math.exp,
  log: Math.log,
  floor: Math.floor,
  ceil: Math.ceil,
  round: Math.round,
  pow: Math.pow,
};

/**
 * Evaluates a scalar CDML v1.0 math expression (`numbers`, `PI`, `E`, `ref(id)`,
 * identifiers in `env`, `+ - * / ^`, parentheses, and standard math functions)
 * using a pure recursive-descent parser (no `Function()` or `eval()`).
 *
 * @param {string | number} expr
 * @param {Record<string, number>} [env={}]
 * @returns {number}
 */
export function evalCdmlScalar(expr, env = {}) {
  if (typeof expr === 'number') return expr;
  const src = String(expr ?? '').trim();
  if (!src) return 0;

  // Fast path for plain numeric literals
  if (/^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(src)) {
    return Number(src);
  }

  // Tokenize strictly into numbers, identifiers, operators, parens, and commas
  const tokens = [];
  const re = /\s*(?:(\d+\.?\d*(?:e[+-]?\d+)?|\.\d+(?:e[+-]?\d+)?)|([A-Za-z_][A-Za-z0-9_]*)|([+\-*/^(),]))\s*/gy;
  let pos = 0;
  while (pos < src.length) {
    re.lastIndex = pos;
    const m = re.exec(src);
    if (!m) {
      throw new Error(`Invalid character in CDML expression at index ${pos}: "${src}"`);
    }
    pos = re.lastIndex;
    if (m[1] !== undefined) tokens.push({ type: 'num', value: Number(m[1]) });
    else if (m[2] !== undefined) tokens.push({ type: 'id', value: m[2] });
    else if (m[3] !== undefined) tokens.push({ type: 'op', value: m[3] });
  }

  let idx = 0;
  const peek = () => tokens[idx];
  const consume = (expectedVal) => {
    const tok = tokens[idx];
    if (!tok || (expectedVal !== undefined && tok.value !== expectedVal)) {
      throw new Error(`Expected "${expectedVal}" in CDML expression: "${src}"`);
    }
    idx++;
    return tok;
  };

  function parseExpr() {
    let left = parseTerm();
    while (peek() && (peek().value === '+' || peek().value === '-')) {
      const op = consume().value;
      const right = parseTerm();
      left = op === '+' ? left + right : left - right;
    }
    return left;
  }

  function parseTerm() {
    let left = parsePower();
    while (peek() && (peek().value === '*' || peek().value === '/')) {
      const op = consume().value;
      const right = parsePower();
      left = op === '*' ? left * right : left / right;
    }
    return left;
  }

  function parsePower() {
    const base = parseUnary();
    if (peek() && peek().value === '^') {
      consume('^');
      const exp = parsePower(); // right-associative exponentiation
      return Math.pow(base, exp);
    }
    return base;
  }

  function parseUnary() {
    if (peek() && (peek().value === '+' || peek().value === '-')) {
      const op = consume().value;
      const val = parseUnary();
      return op === '-' ? -val : val;
    }
    return parsePrimary();
  }

  function parsePrimary() {
    const tok = peek();
    if (!tok) {
      throw new Error(`Unexpected end of CDML expression: "${src}"`);
    }
    if (tok.type === 'num') {
      consume();
      return tok.value;
    }
    if (tok.value === '(') {
      consume('(');
      const val = parseExpr();
      consume(')');
      return val;
    }
    if (tok.type === 'id') {
      const name = consume().value;
      if (peek() && peek().value === '(') {
        consume('(');
        if (name === 'ref') {
          const refTok = consume();
          if (refTok.type !== 'id') {
            throw new Error(`ref() requires an identifier in CDML expression: "${src}"`);
          }
          consume(')');
          return Number(env[refTok.value] ?? 0);
        }
        const fn = SAFE_MATH_FUNCS[name];
        if (!fn) {
          throw new Error(`Unsupported function "${name}()" in CDML expression`);
        }
        const args = [];
        if (!peek() || peek().value !== ')') {
          args.push(parseExpr());
          while (peek() && peek().value === ',') {
            consume(',');
            args.push(parseExpr());
          }
        }
        consume(')');
        return fn(...args);
      }
      if (name === 'PI') return Math.PI;
      if (name === 'E') return Math.E;
      if (Object.prototype.hasOwnProperty.call(env, name)) {
        return Number(env[name]);
      }
      throw new Error(`Unknown identifier "${name}" in CDML expression`);
    }
    throw new Error(`Unexpected token "${tok.value}" in CDML expression: "${src}"`);
  }

  const result = parseExpr();
  if (idx < tokens.length) {
    throw new Error(`Unexpected trailing token "${tokens[idx].value}" in CDML expression: "${src}"`);
  }
  return result;
}

/**
 * Evaluates a rational B-spline (NURBS) curve C(t) = Σ N_{i,p}(t) w_i P_i / Σ N_{i,p}(t) w_i
 * at parameter t using the Cox-de Boor algorithm (matching kernel-zig/src/curve_wire.zig).
 *
 * @param {Array<[number, number]>} ctrlPts - 2D control points
 * @param {number[]} weights - Control point weights (defaults to 1.0)
 * @param {number[]} knots - Non-decreasing knot vector of length ctrlPts.length + degree + 1
 * @param {number} degree - Polynomial degree p >= 1
 * @param {number} t - Parameter value in [knots[p], knots[n+1]]
 * @returns {[number, number]}
 */
export function evalNurbsPoint2D(ctrlPts, weights, knots, degree, t) {
  const n = ctrlPts.length - 1;
  const p = Math.min(degree, n);
  const tMin = knots[p];
  const tMax = knots[n + 1];
  const u = Math.max(tMin, Math.min(tMax, t));

  // Find knot span index
  let span = p;
  if (u >= tMax - 1e-14) {
    span = n;
  } else {
    for (let i = p; i <= n; i++) {
      if (u >= knots[i] && u < knots[i + 1]) {
        span = i;
        break;
      }
    }
  }

  // De Boor triangular table for non-vanishing basis functions N[0..p]
  const N = new Float64Array(p + 1);
  const left = new Float64Array(p + 1);
  const right = new Float64Array(p + 1);
  N[0] = 1.0;

  for (let j = 1; j <= p; j++) {
    left[j] = u - knots[span + 1 - j];
    right[j] = knots[span + j] - u;
    let saved = 0.0;
    for (let r = 0; r < j; r++) {
      const denom = right[r + 1] + left[j - r];
      const temp = Math.abs(denom) > 1e-14 ? N[r] / denom : 0.0;
      N[r] = saved + right[r + 1] * temp;
      saved = left[j - r] * temp;
    }
    N[j] = saved;
  }

  let wx = 0.0;
  let wy = 0.0;
  let wSum = 0.0;
  for (let j = 0; j <= p; j++) {
    const idx = span - p + j;
    const pt = ctrlPts[idx];
    const w = (weights[idx] ?? 1.0) * N[j];
    wx += pt[0] * w;
    wy += pt[1] * w;
    wSum += w;
  }
  const invW = Math.abs(wSum) > 1e-14 ? 1.0 / wSum : 1.0;
  return [wx * invW, wy * invW];
}

/**
 * Builds a clamped uniform knot vector [0..0, ..., 1..1] if none is specified on <curve>.
 * @param {number} ctrlCount
 * @param {number} degree
 * @returns {number[]}
 */
function buildDefaultKnots(ctrlCount, degree) {
  const n = ctrlCount - 1;
  const p = Math.min(degree, n);
  const m = n + p + 1;
  const knots = new Array(m + 1);
  const interior = n - p + 1;
  for (let i = 0; i <= m; i++) {
    if (i <= p) knots[i] = 0.0;
    else if (i >= m - p) knots[i] = 1.0;
    else knots[i] = (i - p) / interior;
  }
  return knots;
}

/**
 * Converts a CDML v1.0 XML document's <sketch> into a FEAScript 2D geometry object.
 * Coordinates are converted from millimeters (CDML default) to meters (SI).
 *
 * @param {string} xmlStr - Full CDML XML document string
 * @param {Object} [options]
 * @param {number} [options.holeSamples=48] - Number of polygon vertices for parametric holes
 * @param {number} [options.outerCurveSamples=72] - Number of polygon vertices for single-curve parametric outer wires
 * @param {number} [options.nurbsSamples=16] - Number of subdivisions per curved (degree >= 2) <curve> segment
 * @param {number} [options.unitScale=0.001] - Scale factor from CDML units to FEAScript units (mm -> m)
 * @returns {{ geometry: { shape: Object, holes: Array }, boundaryNames: string[], vars: Record<string, number> }}
 */
export function cdmlToFEAScriptGeometry(xmlStr, options = {}) {
  const holeSamples = options.holeSamples ?? 48;
  const outerCurveSamples = options.outerCurveSamples ?? 72;
  const nurbsSamples = options.nurbsSamples ?? 16;
  const unitScale = options.unitScale ?? 0.001;

  const doc = new DOMParser().parseFromString(xmlStr, 'application/xml');
  const env = {};

  doc.querySelectorAll('defs > var, parameters > var').forEach((el) => {
    const raw = el.getAttribute('value') ?? el.getAttribute('default') ?? '0';
    env[el.getAttribute('id')] = evalCdmlScalar(raw, env);
  });
  doc.querySelectorAll('defs > expr, parameters > expr').forEach((el) => {
    env[el.getAttribute('id')] = evalCdmlScalar(el.getAttribute('expr') || '0', env);
  });

  const sketch = doc.querySelector('body > sketch, cdml > sketch, sketch');
  if (!sketch) {
    throw new Error('CDML document contains no <sketch> element');
  }

  const ptsMap = new Map();
  sketch.querySelectorAll('vars > point2d').forEach((pt) => {
    ptsMap.set(pt.getAttribute('id'), [
      evalCdmlScalar(pt.getAttribute('u') || '0', env) * unitScale,
      evalCdmlScalar(pt.getAttribute('v') || '0', env) * unitScale,
    ]);
  });

  const sampleParamCurve = (el, nSamples, includeEnd = false) => {
    const paramName = el.getAttribute('param') || 't';
    const [d0, d1] = (el.getAttribute('domain') || '0 1').trim().split(/\s+/).map(Number);
    const uExpr = el.getAttribute('u-expr') || '0';
    const vExpr = el.getAttribute('v-expr') || '0';
    const out = [];
    const limit = includeEnd ? nSamples + 1 : nSamples;
    for (let i = 0; i < limit; i++) {
      const tVal = d0 + ((d1 - d0) * i) / nSamples;
      const localEnv = { ...env, [paramName]: tVal };
      out.push([
        evalCdmlScalar(uExpr, localEnv) * unitScale,
        evalCdmlScalar(vExpr, localEnv) * unitScale,
      ]);
    }
    return out;
  };

  /**
   * Samples a <curve> or <line> element into an ordered list of vertices [P_0, P_1, ..., P_k]
   * including both start and end points.
   * - For <line> or degree-1 <curve> with 2 control points: returns [P_start, P_end] (1 segment).
   * - For degree-1 polyline <curve> with >2 control points: returns all control points.
   * - For degree >= 2 <curve> (NURBS arcs, fillets, splines): evaluates C(t) at `nurbsSamples`
   *   points along the active knot domain [knots[p], knots[n+1]].
   */
  const sampleCurveElement = (seg) => {
    if (seg.tagName === 'line') {
      return [ptsMap.get(seg.getAttribute('p0')), ptsMap.get(seg.getAttribute('p1'))];
    }
    const refs = (seg.getAttribute('ctrl') || '').trim().split(/\s+/).filter(Boolean);
    const ctrlPts = refs.map((id) => ptsMap.get(id)).filter(Boolean);
    if (ctrlPts.length < 2) return ctrlPts;

    const degAttr = seg.getAttribute('deg') || seg.getAttribute('degree') || '1';
    const degree = Math.max(1, parseInt(degAttr, 10) || 1);
    if (degree === 1) {
      return ctrlPts;
    }

    const weightsAttr = (seg.getAttribute('weights') || '').trim();
    const weights = weightsAttr
      ? weightsAttr.split(/\s+/).map((w) => evalCdmlScalar(w, env))
      : ctrlPts.map(() => 1.0);

    const knotsAttr = (seg.getAttribute('knots') || '').trim();
    const p = Math.min(degree, ctrlPts.length - 1);
    const expectedKnots = ctrlPts.length + p + 1;
    let knots = knotsAttr
      ? knotsAttr.split(/\s+/).map((k) => evalCdmlScalar(k, env))
      : [];
    if (knots.length !== expectedKnots) {
      knots = buildDefaultKnots(ctrlPts.length, p);
    }

    const t0 = knots[p];
    const t1 = knots[ctrlPts.length];
    const nSub = Math.max(4, nurbsSamples);
    const pts = [];
    for (let i = 0; i <= nSub; i++) {
      const t = t0 + ((t1 - t0) * i) / nSub;
      pts.push(evalNurbsPoint2D(ctrlPts, weights, knots, p, t));
    }
    return pts;
  };

  let shape = null;
  const holes = [];
  const boundaryNames = [];
  const pushUniqueName = (name) => {
    if (!boundaryNames.includes(name)) boundaryNames.push(name);
  };

  sketch.querySelectorAll('wire').forEach((wire) => {
    const role = wire.getAttribute('role') || 'outer';
    const children = Array.from(wire.children);

    if (role === 'outer') {
      if (children.length === 1 && children[0].tagName === 'param-curve') {
        const pc = children[0];
        const name = pc.getAttribute('id') || 'outer';
        const ring = sampleParamCurve(pc, outerCurveSamples, false);
        const boundaries = [];
        for (let i = 0; i < ring.length; i++) {
          const next = ring[(i + 1) % ring.length];
          boundaries.push(i === ring.length - 1 ? { name } : { name, to: next });
        }
        shape = { start: ring[0], boundaries };
        pushUniqueName(name);
      } else {
        let start = null;
        const rawSegments = [];
        children.forEach((seg, idx) => {
          const name = seg.getAttribute('id') || `edge_${idx}`;
          pushUniqueName(name);
          const pts = seg.tagName === 'param-curve'
            ? sampleParamCurve(seg, nurbsSamples, true)
            : sampleCurveElement(seg);
          if (pts.length >= 2) {
            if (!start) start = pts[0];
            for (let k = 1; k < pts.length; k++) {
              rawSegments.push({ name, to: pts[k] });
            }
          }
        });
        const boundaries = rawSegments.map((seg, i) =>
          i === rawSegments.length - 1 ? { name: seg.name } : seg
        );
        shape = { start, boundaries };
      }
    } else {
      let holePts = [];
      let holeName = wire.getAttribute('id') || 'hole';
      children.forEach((seg) => {
        if (seg.tagName === 'param-curve') {
          holeName = seg.getAttribute('id') || holeName;
          if (children.length === 1) {
            holePts = sampleParamCurve(seg, holeSamples, false);
          } else {
            const pts = sampleParamCurve(seg, nurbsSamples, true);
            holePts = holePts.concat(pts.slice(0, -1));
          }
        } else if (seg.tagName === 'curve' || seg.tagName === 'line') {
          holeName = seg.getAttribute('id') || holeName;
          const pts = sampleCurveElement(seg);
          holePts = holePts.concat(pts.slice(0, -1));
        }
      });
      if (holePts.length >= 3) {
        holes.push({ name: holeName, points: holePts });
        pushUniqueName(holeName);
      }
    }
  });

  return { geometry: { shape, holes }, boundaryNames, vars: env };
}

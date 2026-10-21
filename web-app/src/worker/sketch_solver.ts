import {
  CAD_SKETCH_INVALID_ID,
  CadSketchArc2D,
  CadSketchCircle2D,
  CadSketchConstraint,
  CadSketchConstraintType,
  CadSketchLine2D,
  CadSketchPoint2D,
  CadSolverStatus,
  CadSolveState,
} from '../types/cad';

export interface SolveSketchOptions {
  points: CadSketchPoint2D[];
  lines: CadSketchLine2D[];
  arcs: CadSketchArc2D[];
  circles: CadSketchCircle2D[];
  constraints: CadSketchConstraint[];
  draggedPointId?: number;
  dragTarget?: { x: number; y: number };
  maxIterations?: number;
  convergenceTol?: number;
}

interface ConstraintEq {
  constraintId: number;
  eval: (coords: Float64Array) => number;
}

/**
 * QR decomposition with column pivoting to compute numerical rank and solve least squares.
 */
function qrRankAndSolve(
  A: number[][], // m x n
  b: number[],   // m
  tol: number = 1e-6
): { x: number[]; rank: number } {
  const m = A.length;
  const n = A[0]?.length || 0;
  if (m === 0 || n === 0) {
    return { x: new Array(n).fill(0), rank: 0 };
  }

  // Normal equations with Levenberg-Marquardt regularization:
  // (A^T A + lambda * I) x = A^T b
  // Compute A^T A (n x n) and A^T b (n)
  const AtA: number[][] = Array.from({ length: n }, () => new Array(n).fill(0));
  const Atb: number[] = new Array(n).fill(0);

  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n; j++) {
      let sum = 0;
      for (let k = 0; k < m; k++) {
        sum += A[k][i] * A[k][j];
      }
      AtA[i][j] = sum;
    }
    let sumB = 0;
    for (let k = 0; k < m; k++) {
      sumB += A[k][i] * b[k];
    }
    Atb[i] = sumB;
  }

  // Add small regularization for numerical stability
  const lambda = 1e-7;
  for (let i = 0; i < n; i++) {
    AtA[i][i] += lambda;
  }

  // Solve AtA * x = Atb using Gaussian elimination with partial pivoting
  const M: number[][] = AtA.map((row) => [...row]);
  const rhs = [...Atb];

  for (let col = 0; col < n; col++) {
    // Find pivot
    let maxRow = col;
    let maxVal = Math.abs(M[col][col]);
    for (let r = col + 1; r < n; r++) {
      const val = Math.abs(M[r][col]);
      if (val > maxVal) {
        maxVal = val;
        maxRow = r;
      }
    }

    if (maxVal < 1e-12) continue; // Singular / near-singular column

    if (maxRow !== col) {
      const tmpRow = M[col];
      M[col] = M[maxRow];
      M[maxRow] = tmpRow;
      const tmpVal = rhs[col];
      rhs[col] = rhs[maxRow];
      rhs[maxRow] = tmpVal;
    }

    const pivot = M[col][col];
    for (let r = col + 1; r < n; r++) {
      const factor = M[r][col] / pivot;
      for (let c = col; c < n; c++) {
        M[r][c] -= factor * M[col][c];
      }
      rhs[r] -= factor * rhs[col];
    }
  }

  const x = new Array(n).fill(0);
  for (let i = n - 1; i >= 0; i--) {
    let sum = rhs[i];
    for (let j = i + 1; j < n; j++) {
      sum -= M[i][j] * x[j];
    }
    x[i] = Math.abs(M[i][i]) > 1e-12 ? sum / M[i][i] : 0;
  }

  // Compute rank of A using SVD-like row reduction or QR on A
  // A is m x n
  const Acopy = A.map((r) => [...r]);
  let rank = 0;
  const leadCols = Math.min(m, n);

  for (let c = 0; c < leadCols; c++) {
    let pivotRow = rank;
    let maxVal = 0;
    for (let r = rank; r < m; r++) {
      const val = Math.abs(Acopy[r][c]);
      if (val > maxVal) {
        maxVal = val;
        pivotRow = r;
      }
    }
    if (maxVal > tol) {
      const tmp = Acopy[rank];
      Acopy[rank] = Acopy[pivotRow];
      Acopy[pivotRow] = tmp;

      const p = Acopy[rank][c];
      for (let r = rank + 1; r < m; r++) {
        const factor = Acopy[r][c] / p;
        for (let j = c; j < n; j++) {
          Acopy[r][j] -= factor * Acopy[rank][j];
        }
      }
      rank++;
    }
  }

  return { x, rank };
}

/**
 * 2D Geometric Constraint Solver (PlaneGCS-compliant).
 */
export function solveSketch(options: SolveSketchOptions): CadSolverStatus {
  const {
    points,
    lines,
    arcs,
    circles,
    constraints,
    draggedPointId,
    dragTarget,
    maxIterations = 60,
    convergenceTol = 1e-6,
  } = options;

  const pointCount = points.length;
  // Map point ID -> index
  const pointIdToIndex = new Map<number, number>();
  for (let i = 0; i < pointCount; i++) {
    pointIdToIndex.set(points[i].id, i);
  }

  const lineIdToLine = new Map<number, CadSketchLine2D>();
  for (const l of lines) {
    lineIdToLine.set(l.id, l);
  }

  const arcIdToArc = new Map<number, CadSketchArc2D>();
  for (const a of arcs) {
    arcIdToArc.set(a.id, a);
  }

  const circleIdToCircle = new Map<number, CadSketchCircle2D>();
  for (const c of circles) {
    circleIdToCircle.set(c.id, c);
  }

  // Identify variable indices for free points
  // If point is fixed, its (x, y) are not variables
  const varMap: number[] = new Array(pointCount * 2).fill(-1);
  let varCount = 0;

  for (let i = 0; i < pointCount; i++) {
    const pt = points[i];
    if (!pt.is_fixed) {
      varMap[i * 2] = varCount++;     // x var
      varMap[i * 2 + 1] = varCount++; // y var
    }
  }

  // Initialize coordinate vector
  const coords = new Float64Array(pointCount * 2);
  for (let i = 0; i < pointCount; i++) {
    coords[i * 2] = points[i].x;
    coords[i * 2 + 1] = points[i].y;
  }

  // If a point is being dragged and unconstrained, update directly
  if (draggedPointId !== undefined && dragTarget) {
    const dragIdx = pointIdToIndex.get(draggedPointId);
    if (dragIdx !== undefined && !points[dragIdx].is_fixed) {
      if (constraints.length === 0) {
        coords[dragIdx * 2] = dragTarget.x;
        coords[dragIdx * 2 + 1] = dragTarget.y;
      }
    }
  }

  // Build list of constraint equations
  const equations: ConstraintEq[] = [];

  for (const c of constraints) {
    const id = c.id;
    switch (c.type) {
      case CadSketchConstraintType.COINCIDENT: {
        const p1Idx = pointIdToIndex.get(c.entity1_id);
        const p2Idx = pointIdToIndex.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        if (p1Idx !== undefined && p2Idx !== undefined) {
          equations.push({
            constraintId: id,
            eval: (v) => v[p1Idx * 2] - v[p2Idx * 2],
          });
          equations.push({
            constraintId: id,
            eval: (v) => v[p1Idx * 2 + 1] - v[p2Idx * 2 + 1],
          });
        } else if (p1Idx !== undefined && c.entity2_id !== undefined) {
          // Point on line
          const line = lineIdToLine.get(c.entity2_id);
          if (line) {
            const paIdx = pointIdToIndex.get(line.start_point_id);
            const pbIdx = pointIdToIndex.get(line.end_point_id);
            if (paIdx !== undefined && pbIdx !== undefined) {
              equations.push({
                constraintId: id,
                eval: (v) => {
                  const px = v[p1Idx * 2], py = v[p1Idx * 2 + 1];
                  const ax = v[paIdx * 2], ay = v[paIdx * 2 + 1];
                  const bx = v[pbIdx * 2], by = v[pbIdx * 2 + 1];
                  return (py - ay) * (bx - ax) - (px - ax) * (by - ay);
                },
              });
            }
          }
        }
        break;
      }

      case CadSketchConstraintType.HORIZONTAL: {
        // Line horizontal or 2 points horizontal
        const line = lineIdToLine.get(c.entity1_id);
        if (line) {
          const p1Idx = pointIdToIndex.get(line.start_point_id);
          const p2Idx = pointIdToIndex.get(line.end_point_id);
          if (p1Idx !== undefined && p2Idx !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => v[p2Idx * 2 + 1] - v[p1Idx * 2 + 1],
            });
          }
        } else {
          const p1Idx = pointIdToIndex.get(c.entity1_id);
          const p2Idx = pointIdToIndex.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
          if (p1Idx !== undefined && p2Idx !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => v[p2Idx * 2 + 1] - v[p1Idx * 2 + 1],
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.VERTICAL: {
        // Line vertical or 2 points vertical
        const line = lineIdToLine.get(c.entity1_id);
        if (line) {
          const p1Idx = pointIdToIndex.get(line.start_point_id);
          const p2Idx = pointIdToIndex.get(line.end_point_id);
          if (p1Idx !== undefined && p2Idx !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => v[p2Idx * 2] - v[p1Idx * 2],
            });
          }
        } else {
          const p1Idx = pointIdToIndex.get(c.entity1_id);
          const p2Idx = pointIdToIndex.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
          if (p1Idx !== undefined && p2Idx !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => v[p2Idx * 2] - v[p1Idx * 2],
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.PARALLEL: {
        const l1 = lineIdToLine.get(c.entity1_id);
        const l2 = lineIdToLine.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        if (l1 && l2) {
          const p1a = pointIdToIndex.get(l1.start_point_id);
          const p1b = pointIdToIndex.get(l1.end_point_id);
          const p2a = pointIdToIndex.get(l2.start_point_id);
          const p2b = pointIdToIndex.get(l2.end_point_id);
          if (p1a !== undefined && p1b !== undefined && p2a !== undefined && p2b !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx1 = v[p1b * 2] - v[p1a * 2];
                const dy1 = v[p1b * 2 + 1] - v[p1a * 2 + 1];
                const dx2 = v[p2b * 2] - v[p2a * 2];
                const dy2 = v[p2b * 2 + 1] - v[p2a * 2 + 1];
                return dx1 * dy2 - dy1 * dx2;
              },
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.PERPENDICULAR: {
        const l1 = lineIdToLine.get(c.entity1_id);
        const l2 = lineIdToLine.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        if (l1 && l2) {
          const p1a = pointIdToIndex.get(l1.start_point_id);
          const p1b = pointIdToIndex.get(l1.end_point_id);
          const p2a = pointIdToIndex.get(l2.start_point_id);
          const p2b = pointIdToIndex.get(l2.end_point_id);
          if (p1a !== undefined && p1b !== undefined && p2a !== undefined && p2b !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx1 = v[p1b * 2] - v[p1a * 2];
                const dy1 = v[p1b * 2 + 1] - v[p1a * 2 + 1];
                const dx2 = v[p2b * 2] - v[p2a * 2];
                const dy2 = v[p2b * 2 + 1] - v[p2a * 2 + 1];
                return dx1 * dx2 + dy1 * dy2;
              },
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.DISTANCE: {
        const targetDist = c.parameter_value ?? 1.0;
        const line = lineIdToLine.get(c.entity1_id);
        if (line) {
          const p1 = pointIdToIndex.get(line.start_point_id);
          const p2 = pointIdToIndex.get(line.end_point_id);
          if (p1 !== undefined && p2 !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx = v[p2 * 2] - v[p1 * 2];
                const dy = v[p2 * 2 + 1] - v[p1 * 2 + 1];
                return Math.sqrt(dx * dx + dy * dy) - targetDist;
              },
            });
          }
        } else {
          const p1 = pointIdToIndex.get(c.entity1_id);
          const p2 = pointIdToIndex.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
          if (p1 !== undefined && p2 !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx = v[p2 * 2] - v[p1 * 2];
                const dy = v[p2 * 2 + 1] - v[p1 * 2 + 1];
                return Math.sqrt(dx * dx + dy * dy) - targetDist;
              },
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.EQUAL: {
        const l1 = lineIdToLine.get(c.entity1_id);
        const l2 = lineIdToLine.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        if (l1 && l2) {
          const p1a = pointIdToIndex.get(l1.start_point_id);
          const p1b = pointIdToIndex.get(l1.end_point_id);
          const p2a = pointIdToIndex.get(l2.start_point_id);
          const p2b = pointIdToIndex.get(l2.end_point_id);
          if (p1a !== undefined && p1b !== undefined && p2a !== undefined && p2b !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx1 = v[p1b * 2] - v[p1a * 2];
                const dy1 = v[p1b * 2 + 1] - v[p1a * 2 + 1];
                const dx2 = v[p2b * 2] - v[p2a * 2];
                const dy2 = v[p2b * 2 + 1] - v[p2a * 2 + 1];
                return Math.sqrt(dx1 * dx1 + dy1 * dy1) - Math.sqrt(dx2 * dx2 + dy2 * dy2);
              },
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.RADIUS: {
        const targetRadius = c.parameter_value ?? 1.0;
        const arc = arcIdToArc.get(c.entity1_id);
        const circle = circleIdToCircle.get(c.entity1_id);
        if (arc) {
          const pc = pointIdToIndex.get(arc.center_point_id);
          const ps = pointIdToIndex.get(arc.start_point_id);
          if (pc !== undefined && ps !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx = v[ps * 2] - v[pc * 2];
                const dy = v[ps * 2 + 1] - v[pc * 2 + 1];
                return Math.sqrt(dx * dx + dy * dy) - targetRadius;
              },
            });
          }
        } else if (circle) {
          // Circle radius parameter
          circle.radius = targetRadius;
        }
        break;
      }

      case CadSketchConstraintType.ANGLE: {
        const targetAngleRad = c.parameter_value ?? (Math.PI / 2);
        const l1 = lineIdToLine.get(c.entity1_id);
        const l2 = lineIdToLine.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        if (l1 && l2) {
          const p1a = pointIdToIndex.get(l1.start_point_id);
          const p1b = pointIdToIndex.get(l1.end_point_id);
          const p2a = pointIdToIndex.get(l2.start_point_id);
          const p2b = pointIdToIndex.get(l2.end_point_id);
          if (p1a !== undefined && p1b !== undefined && p2a !== undefined && p2b !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx1 = v[p1b * 2] - v[p1a * 2];
                const dy1 = v[p1b * 2 + 1] - v[p1a * 2 + 1];
                const dx2 = v[p2b * 2] - v[p2a * 2];
                const dy2 = v[p2b * 2 + 1] - v[p2a * 2 + 1];
                const dot = dx1 * dx2 + dy1 * dy2;
                const len1 = Math.sqrt(dx1 * dx1 + dy1 * dy1);
                const len2 = Math.sqrt(dx2 * dx2 + dy2 * dy2);
                if (len1 < 1e-9 || len2 < 1e-9) return 0;
                return dot / (len1 * len2) - Math.cos(targetAngleRad);
              },
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.TANGENT: {
        // Line tangent to circle/arc
        const line = lineIdToLine.get(c.entity1_id);
        const arc = arcIdToArc.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        const circle = circleIdToCircle.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        const radius = arc ? arc.radius : (circle ? circle.radius : 1.0);
        const centerId = arc ? arc.center_point_id : (circle ? circle.center_point_id : undefined);
        if (line && centerId !== undefined) {
          const pa = pointIdToIndex.get(line.start_point_id);
          const pb = pointIdToIndex.get(line.end_point_id);
          const pc = pointIdToIndex.get(centerId);
          if (pa !== undefined && pb !== undefined && pc !== undefined) {
            equations.push({
              constraintId: id,
              eval: (v) => {
                const x1 = v[pa * 2], y1 = v[pa * 2 + 1];
                const x2 = v[pb * 2], y2 = v[pb * 2 + 1];
                const xc = v[pc * 2], yc = v[pc * 2 + 1];
                const dx = x2 - x1, dy = y2 - y1;
                const len = Math.sqrt(dx * dx + dy * dy);
                if (len < 1e-9) return 0;
                const dist = Math.abs(dx * (y1 - yc) - dy * (x1 - xc)) / len;
                return dist - radius;
              },
            });
          }
        }
        break;
      }

      case CadSketchConstraintType.SYMMETRIC: {
        // Points p1, p2 symmetric across line
        const p1 = pointIdToIndex.get(c.entity1_id);
        const p2 = pointIdToIndex.get(c.entity2_id ?? CAD_SKETCH_INVALID_ID);
        const line = lineIdToLine.get(c.entity3_id ?? CAD_SKETCH_INVALID_ID);
        if (p1 !== undefined && p2 !== undefined && line) {
          const pa = pointIdToIndex.get(line.start_point_id);
          const pb = pointIdToIndex.get(line.end_point_id);
          if (pa !== undefined && pb !== undefined) {
            // Midpoint on line
            equations.push({
              constraintId: id,
              eval: (v) => {
                const mx = (v[p1 * 2] + v[p2 * 2]) / 2;
                const my = (v[p1 * 2 + 1] + v[p2 * 2 + 1]) / 2;
                const ax = v[pa * 2], ay = v[pa * 2 + 1];
                const bx = v[pb * 2], by = v[pb * 2 + 1];
                return (my - ay) * (bx - ax) - (mx - ax) * (by - ay);
              },
            });
            // Line between p1 and p2 is perpendicular to symmetry line
            equations.push({
              constraintId: id,
              eval: (v) => {
                const dx = v[p2 * 2] - v[p1 * 2];
                const dy = v[p2 * 2 + 1] - v[p1 * 2 + 1];
                const lax = v[pb * 2] - v[pa * 2];
                const lay = v[pb * 2 + 1] - v[pa * 2 + 1];
                return dx * lax + dy * lay;
              },
            });
          }
        }
        break;
      }
    }
  }

  // Also include soft dragging equation if dragging and constraints exist
  if (draggedPointId !== undefined && dragTarget && constraints.length > 0) {
    const dIdx = pointIdToIndex.get(draggedPointId);
    if (dIdx !== undefined && !points[dIdx].is_fixed) {
      const weight = 0.05;
      equations.push({
        constraintId: CAD_SKETCH_INVALID_ID,
        eval: (v) => weight * (v[dIdx * 2] - dragTarget.x),
      });
      equations.push({
        constraintId: CAD_SKETCH_INVALID_ID,
        eval: (v) => weight * (v[dIdx * 2 + 1] - dragTarget.y),
      });
    }
  }

  const m = equations.length;
  const n = varCount;

  let iterations = 0;
  let maxResidual = 0;
  const h = 1e-7;

  if (m === 0 || n === 0) {
    // No equations or no free variables
    const dof = Math.max(0, n);
    return {
      solve_state: dof === 0 ? CadSolveState.SOLVED : CadSolveState.UNDER_CONSTRAINED,
      degrees_of_freedom: dof,
      iterations: 0,
      max_residual: 0,
      updated_coords: coords,
      coord_count: pointCount,
      conflicting_constraint_ids: new Uint32Array(0),
      conflicting_count: 0,
    };
  }

  // Levenberg-Marquardt iteration loop
  for (let it = 0; it < maxIterations; it++) {
    iterations++;

    // Evaluate residual vector F
    const F: number[] = new Array(m);
    maxResidual = 0;
    for (let i = 0; i < m; i++) {
      const res = equations[i].eval(coords);
      F[i] = res;
      // Do not count soft dragging residual toward convergence check
      if (equations[i].constraintId !== CAD_SKETCH_INVALID_ID) {
        maxResidual = Math.max(maxResidual, Math.abs(res));
      }
    }

    if (maxResidual < convergenceTol && it > 0) {
      break;
    }

    // Compute Jacobian J (m x n) via finite differences
    const J: number[][] = Array.from({ length: m }, () => new Array(n).fill(0));

    for (let pIdx = 0; pIdx < pointCount; pIdx++) {
      const xVar = varMap[pIdx * 2];
      const yVar = varMap[pIdx * 2 + 1];

      if (xVar >= 0) {
        const orig = coords[pIdx * 2];
        coords[pIdx * 2] = orig + h;
        const resPlus: number[] = new Array(m);
        for (let i = 0; i < m; i++) resPlus[i] = equations[i].eval(coords);

        coords[pIdx * 2] = orig - h;
        for (let i = 0; i < m; i++) {
          const resMinus = equations[i].eval(coords);
          J[i][xVar] = (resPlus[i] - resMinus) / (2 * h);
        }
        coords[pIdx * 2] = orig;
      }

      if (yVar >= 0) {
        const orig = coords[pIdx * 2 + 1];
        coords[pIdx * 2 + 1] = orig + h;
        const resPlus: number[] = new Array(m);
        for (let i = 0; i < m; i++) resPlus[i] = equations[i].eval(coords);

        coords[pIdx * 2 + 1] = orig - h;
        for (let i = 0; i < m; i++) {
          const resMinus = equations[i].eval(coords);
          J[i][yVar] = (resPlus[i] - resMinus) / (2 * h);
        }
        coords[pIdx * 2 + 1] = orig;
      }
    }

    // Solve for step delta: J * delta = -F
    const negF = F.map((v) => -v);
    const result = qrRankAndSolve(J, negF);

    // Apply step with line search / damping
    let stepNorm = 0;
    for (let pIdx = 0; pIdx < pointCount; pIdx++) {
      const xVar = varMap[pIdx * 2];
      const yVar = varMap[pIdx * 2 + 1];
      if (xVar >= 0) {
        coords[pIdx * 2] += result.x[xVar];
        stepNorm += result.x[xVar] * result.x[xVar];
      }
      if (yVar >= 0) {
        coords[pIdx * 2 + 1] += result.x[yVar];
        stepNorm += result.x[yVar] * result.x[yVar];
      }
    }

    if (Math.sqrt(stepNorm) < 1e-6) {
      break;
    }
  }

  // Final evaluation of residuals and rank (excluding soft drag equations for DOF)
  const nonDragEquations = equations.filter((e) => e.constraintId !== CAD_SKETCH_INVALID_ID);
  const mHard = nonDragEquations.length;

  maxResidual = 0;
  const hardResiduals: { constraintId: number; error: number }[] = [];
  for (const eq of nonDragEquations) {
    const err = Math.abs(eq.eval(coords));
    maxResidual = Math.max(maxResidual, err);
    hardResiduals.push({ constraintId: eq.constraintId, error: err });
  }

  // Compute final rank on hard constraints
  let hardRank = 0;
  if (mHard > 0 && n > 0) {
    const Jhard: number[][] = Array.from({ length: mHard }, () => new Array(n).fill(0));
    for (let pIdx = 0; pIdx < pointCount; pIdx++) {
      const xVar = varMap[pIdx * 2];
      const yVar = varMap[pIdx * 2 + 1];

      if (xVar >= 0) {
        const orig = coords[pIdx * 2];
        coords[pIdx * 2] = orig + h;
        const resPlus: number[] = new Array(mHard);
        for (let i = 0; i < mHard; i++) resPlus[i] = nonDragEquations[i].eval(coords);

        coords[pIdx * 2] = orig - h;
        for (let i = 0; i < mHard; i++) {
          const resMinus = nonDragEquations[i].eval(coords);
          Jhard[i][xVar] = (resPlus[i] - resMinus) / (2 * h);
        }
        coords[pIdx * 2] = orig;
      }

      if (yVar >= 0) {
        const orig = coords[pIdx * 2 + 1];
        coords[pIdx * 2 + 1] = orig + h;
        const resPlus: number[] = new Array(mHard);
        for (let i = 0; i < mHard; i++) resPlus[i] = nonDragEquations[i].eval(coords);

        coords[pIdx * 2 + 1] = orig - h;
        for (let i = 0; i < mHard; i++) {
          const resMinus = nonDragEquations[i].eval(coords);
          Jhard[i][yVar] = (resPlus[i] - resMinus) / (2 * h);
        }
        coords[pIdx * 2 + 1] = orig;
      }
    }

    const { rank: computedRank } = qrRankAndSolve(Jhard, new Array(mHard).fill(0));
    hardRank = computedRank;
  }

  const remainingDof = Math.max(0, n - hardRank);

  let solveState: CadSolveState;
  const conflictingIds: number[] = [];

  const isConverged = maxResidual < convergenceTol;

  if (isConverged) {
    if (mHard > hardRank) {
      solveState = CadSolveState.OVER_CONSTRAINED;
    } else if (remainingDof === 0) {
      solveState = CadSolveState.SOLVED;
    } else {
      solveState = CadSolveState.UNDER_CONSTRAINED;
    }
  } else {
    solveState = CadSolveState.CONFLICTING;
    // Collect IDs of equations with highest residuals
    const sorted = [...hardResiduals].sort((a, b) => b.error - a.error);
    const seen = new Set<number>();
    for (const item of sorted) {
      if (item.error > convergenceTol && !seen.has(item.constraintId)) {
        seen.add(item.constraintId);
        conflictingIds.push(item.constraintId);
      }
    }
  }

  const conflictingArray = new Uint32Array(conflictingIds);

  return {
    solve_state: solveState,
    degrees_of_freedom: remainingDof,
    iterations,
    max_residual: maxResidual,
    updated_coords: coords,
    coord_count: pointCount,
    conflicting_constraint_ids: conflictingArray,
    conflicting_count: conflictingArray.length,
  };
}

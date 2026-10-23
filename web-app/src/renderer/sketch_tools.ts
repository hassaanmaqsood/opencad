import { CadSketchPoint2D } from '../types/cad';

export type SketchToolType =
  | 'select'
  | 'line'
  | 'rectangle'
  | 'circle'
  | 'arc'
  | 'spline'
  | 'slot'
  | 'text'
  | 'fillet'
  | 'chamfer'
  | 'offset'
  | 'trim';

export interface SnapTarget {
  type: 'point' | 'origin' | 'grid';
  pointId?: number;
  u: number;
  v: number;
  label: string;
}

export interface InferenceState {
  type: 'horizontal' | 'vertical' | 'none';
  u: number;
  v: number;
}

export class SketchTools {
  public activeTool: SketchToolType = 'select';
  public isConstruction: boolean = false;
  private step: number = 0;
  private startPoint: { u: number; v: number; pointId?: number } | null = null;
  private intermediatePoint: { u: number; v: number; pointId?: number } | null = null;

  public snapTarget: SnapTarget | null = null;
  public inference: InferenceState = { type: 'none', u: 0, v: 0 };

  private snapThreshold: number = 0.25; // in sketch coordinate units

  public setTool(tool: SketchToolType): void {
    this.activeTool = tool;
    this.reset();
  }

  public toggleConstruction(): boolean {
    this.isConstruction = !this.isConstruction;
    return this.isConstruction;
  }

  public reset(): void {
    this.step = 0;
    this.startPoint = null;
    this.intermediatePoint = null;
    this.snapTarget = null;
    this.inference = { type: 'none', u: 0, v: 0 };
  }

  /**
   * Find magnetic snap point (existing points, origin, or fine grid).
   */
  public computeSnap(
    u: number,
    v: number,
    existingPoints: CadSketchPoint2D[],
    gridSnap: boolean = true
  ): SnapTarget | null {
    // 1. Check snap to existing sketch points
    let closestPt: CadSketchPoint2D | null = null;
    let minDist = this.snapThreshold;

    for (const pt of existingPoints) {
      const d = Math.hypot(pt.x - u, pt.y - v);
      if (d < minDist) {
        minDist = d;
        closestPt = pt;
      }
    }

    if (closestPt) {
      return {
        type: 'point',
        pointId: closestPt.id,
        u: closestPt.x,
        v: closestPt.y,
        label: `Point #${closestPt.id}`,
      };
    }

    // 2. Check snap to origin (0, 0)
    const distToOrigin = Math.hypot(u, v);
    if (distToOrigin < this.snapThreshold) {
      return {
        type: 'origin',
        u: 0,
        v: 0,
        label: 'Origin (0, 0)',
      };
    }

    // 3. Grid snap
    if (gridSnap) {
      const gridStep = 0.5;
      const snapU = Math.round(u / gridStep) * gridStep;
      const snapV = Math.round(v / gridStep) * gridStep;
      if (Math.hypot(snapU - u, snapV - v) < this.snapThreshold * 0.4) {
        return {
          type: 'grid',
          u: snapU,
          v: snapV,
          label: `Grid (${snapU.toFixed(1)}, ${snapV.toFixed(1)})`,
        };
      }
    }

    return null;
  }

  /**
   * Compute automatic horizontal/vertical inference glyphs.
   */
  public computeInference(startU: number, startV: number, currentU: number, currentV: number): InferenceState {
    const du = Math.abs(currentU - startU);
    const dv = Math.abs(currentV - startV);
    const angle = Math.atan2(Math.abs(currentV - startV), Math.abs(currentU - startU));

    // Near horizontal: angle < 6 degrees or dv < 0.1
    if (dv < 0.15 || angle < 0.1) {
      return {
        type: 'horizontal',
        u: currentU,
        v: startV, // auto-align
      };
    }

    // Near vertical: angle > 84 degrees or du < 0.1
    if (du < 0.15 || Math.abs(angle - Math.PI / 2) < 0.1) {
      return {
        type: 'vertical',
        u: startU, // auto-align
        v: currentV,
      };
    }

    return { type: 'none', u: currentU, v: currentV };
  }

  public getStartPoint() {
    return this.startPoint;
  }

  public getStep() {
    return this.step;
  }

  public setStartPoint(pt: { u: number; v: number; pointId?: number }) {
    this.startPoint = pt;
    this.step = 1;
  }

  public setIntermediatePoint(pt: { u: number; v: number; pointId?: number }) {
    this.intermediatePoint = pt;
    this.step = 2;
  }

  public getIntermediatePoint() {
    return this.intermediatePoint;
  }
}

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import {
  CAD_SKETCH_INVALID_ID,
  CadSketchArc2D,
  CadSketchCircle2D,
  CadSketchConstraint,
  CadSketchConstraintType,
  CadSketchLine2D,
  CadSketchPoint2D,
  CadSolveState,
} from '../types/cad';
import { CadWorkerBridge } from '../worker/worker_bridge';
import { SketchTools, SketchToolType } from './sketch_tools';

export type DatumPlane = 'XY' | 'YZ' | 'XZ';

export interface SketchManagerState {
  inSketchMode: boolean;
  activePlane: DatumPlane;
  activeTool: SketchToolType;
  dof: number;
  solveState: CadSolveState;
  pointCount: number;
  lineCount: number;
  arcCount: number;
  circleCount: number;
  constraintCount: number;
  selectedEntityIds: { points: number[]; lines: number[]; arcs: number[]; circles: number[] };
  selectedConstraintId: number | null;
}

export class SketchManager {
  private scene: THREE.Scene;
  private camera: THREE.PerspectiveCamera;
  private canvas: HTMLCanvasElement;
  private controls: OrbitControls;
  private bridge: CadWorkerBridge;

  public inSketchMode: boolean = false;
  public activePlane: DatumPlane = 'XY';
  public tools: SketchTools = new SketchTools();

  // Three.js visual groups
  public group: THREE.Group = new THREE.Group();
  private gridGroup: THREE.Group = new THREE.Group();
  private entityGroup: THREE.Group = new THREE.Group();
  private previewGroup: THREE.Group = new THREE.Group();
  private overlayGroup: THREE.Group = new THREE.Group();

  // Data Store
  public points: CadSketchPoint2D[] = [];
  public lines: CadSketchLine2D[] = [];
  public arcs: CadSketchArc2D[] = [];
  public circles: CadSketchCircle2D[] = [];
  public constraints: CadSketchConstraint[] = [];
  private nextId: number = 1;

  // Solver outcome
  public solveState: CadSolveState = CadSolveState.UNDER_CONSTRAINED;
  public dof: number = 0;
  public conflictingIds: Set<number> = new Set();

  // Selection
  public selectedPointIds: Set<number> = new Set();
  public selectedLineIds: Set<number> = new Set();
  public selectedArcIds: Set<number> = new Set();
  public selectedCircleIds: Set<number> = new Set();
  public selectedConstraintId: number | null = null;

  // Dragging state
  private draggingPointId: number | null = null;
  private isPointerDown: boolean = false;
  private pointerDownClient: { x: number; y: number } = { x: 0, y: 0 };
  private isSolving: boolean = false;
  private solveQueue: Array<{
    resolve: () => void;
    reject: (err: any) => void;
    draggedPointId?: number;
    dragTarget?: { x: number; y: number };
  }> = [];

  // Mesh caches for zero-allocation 60 FPS updates
  private pointMeshes = new Map<number, THREE.Mesh>();
  private lineMeshes = new Map<number, THREE.Line>();
  private circleMeshes = new Map<number, THREE.Line>();
  private arcMeshes = new Map<number, THREE.Line>();
  private sharedSphereGeom = new THREE.SphereGeometry(0.12, 16, 16);

  // Previous camera state for restore on exit
  private prevCameraPos: THREE.Vector3 = new THREE.Vector3();
  private prevCameraTarget: THREE.Vector3 = new THREE.Vector3();
  private prevControlsRotate: boolean = true;

  // Callbacks
  public onStateChange?: (state: SketchManagerState) => void;
  public onCoordinateChange?: (u: number, v: number) => void;
  public onRequestDimensionEdit?: (constraint: CadSketchConstraint, clientX: number, clientY: number) => void;

  private raycaster = new THREE.Raycaster();
  private mouse = new THREE.Vector2();

  constructor(
    scene: THREE.Scene,
    camera: THREE.PerspectiveCamera,
    canvas: HTMLCanvasElement,
    controls: OrbitControls,
    bridge: CadWorkerBridge
  ) {
    this.scene = scene;
    this.camera = camera;
    this.canvas = canvas;
    this.controls = controls;
    this.bridge = bridge;

    this.group.name = 'CadSketchGroup';
    this.group.visible = false;
    this.group.add(this.gridGroup);
    this.group.add(this.entityGroup);
    this.group.add(this.previewGroup);
    this.group.add(this.overlayGroup);
    this.scene.add(this.group);

    this.setupListeners();
  }

  /* ------------------------------------------------------------------------- */
  /* Plane Transformations & Raycasting                                        */
  /* ------------------------------------------------------------------------- */

  public planeToWorld(u: number, v: number): THREE.Vector3 {
    switch (this.activePlane) {
      case 'XY':
        return new THREE.Vector3(u, v, 0.001);
      case 'XZ':
        return new THREE.Vector3(u, 0.001, v);
      case 'YZ':
        return new THREE.Vector3(0.001, u, v);
    }
  }

  public worldToPlane(pos: THREE.Vector3): { u: number; v: number } {
    switch (this.activePlane) {
      case 'XY':
        return { u: pos.x, v: pos.y };
      case 'XZ':
        return { u: pos.x, v: pos.z };
      case 'YZ':
        return { u: pos.y, v: pos.z };
    }
  }

  private getPlane(): THREE.Plane {
    switch (this.activePlane) {
      case 'XY':
        return new THREE.Plane(new THREE.Vector3(0, 0, 1), 0);
      case 'XZ':
        return new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
      case 'YZ':
        return new THREE.Plane(new THREE.Vector3(1, 0, 0), 0);
    }
  }

  public raycastPlane(clientX: number, clientY: number): { u: number; v: number } | null {
    const rect = this.canvas.getBoundingClientRect();
    this.mouse.x = ((clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((clientY - rect.top) / rect.height) * 2 + 1;

    this.raycaster.setFromCamera(this.mouse, this.camera);
    const plane = this.getPlane();
    const intersect = new THREE.Vector3();
    const hit = this.raycaster.ray.intersectPlane(plane, intersect);
    if (!hit) return null;
    return this.worldToPlane(intersect);
  }

  /* ------------------------------------------------------------------------- */
  /* Sketch Lifecycle & Camera Alignment                                      */
  /* ------------------------------------------------------------------------- */

  public enterSketchMode(plane: DatumPlane): void {
    this.inSketchMode = true;
    this.activePlane = plane;
    this.group.visible = true;

    // Save previous camera setup
    this.prevCameraPos.copy(this.camera.position);
    this.prevCameraTarget.copy(this.controls.target);
    this.prevControlsRotate = this.controls.enableRotate;

    // Animate / align camera squarely facing chosen datum plane
    this.alignCameraToPlane(plane);

    // Disable 3D orbit rotation, keep 2D pan and zoom
    this.controls.enableRotate = false;
    this.controls.enablePan = true;
    this.controls.enableZoom = true;

    this.rebuildGrid();
    this.renderEntities();
    this.emitState();
  }

  public exitSketchMode(): void {
    this.inSketchMode = false;
    this.group.visible = false;
    this.tools.reset();

    // Restore previous 3D orbit controls and camera
    this.controls.enableRotate = this.prevControlsRotate;
    this.controls.target.copy(this.prevCameraTarget);
    this.camera.position.copy(this.prevCameraPos);
    this.camera.lookAt(this.controls.target);
    this.controls.update();

    this.emitState();
  }

  private alignCameraToPlane(plane: DatumPlane): void {
    const dist = 12.0;
    this.controls.target.set(0, 0, 0);

    switch (plane) {
      case 'XY':
        this.camera.position.set(0, 0, dist);
        this.camera.up.set(0, 1, 0);
        break;
      case 'XZ':
        this.camera.position.set(0, dist, 0);
        this.camera.up.set(0, 0, -1);
        break;
      case 'YZ':
        this.camera.position.set(dist, 0, 0);
        this.camera.up.set(0, 1, 0);
        break;
    }

    this.camera.lookAt(0, 0, 0);
    this.controls.update();
  }

  private rebuildGrid(): void {
    // Clear existing grid
    while (this.gridGroup.children.length > 0) {
      const child = this.gridGroup.children.pop()!;
      if ((child as any).geometry) (child as any).geometry.dispose();
      if ((child as any).material) (child as any).material.dispose();
    }

    const size = 16;
    const divisions = 32;
    const grid = new THREE.GridHelper(size, divisions, 0x3b82f6, 0x1e293b);
    (grid.material as THREE.Material).transparent = true;
    (grid.material as THREE.Material).opacity = 0.55;

    // Rotate grid to align with datum plane
    switch (this.activePlane) {
      case 'XY':
        grid.rotation.x = Math.PI / 2;
        break;
      case 'XZ':
        // Default GridHelper is XZ
        break;
      case 'YZ':
        grid.rotation.z = Math.PI / 2;
        break;
    }
    this.gridGroup.add(grid);

    // Plane boundary frame
    const planeGeom = new THREE.PlaneGeometry(size, size);
    const planeEdges = new THREE.EdgesGeometry(planeGeom);
    const planeLineMat = new THREE.LineBasicMaterial({
      color: 0x38bdf8,
      transparent: true,
      opacity: 0.35,
    });
    const planeWireframe = new THREE.LineSegments(planeEdges, planeLineMat);
    switch (this.activePlane) {
      case 'XY':
        break;
      case 'XZ':
        planeWireframe.rotation.x = -Math.PI / 2;
        break;
      case 'YZ':
        planeWireframe.rotation.y = Math.PI / 2;
        break;
    }
    this.gridGroup.add(planeWireframe);

    // Origin marker (small red/green axes cross)
    const axes = new THREE.AxesHelper(1.2);
    (axes.material as THREE.Material).depthTest = false;
    axes.renderOrder = 2;
    this.gridGroup.add(axes);
  }

  /* ------------------------------------------------------------------------- */
  /* Solver Synchronization                                                    */
  /* ------------------------------------------------------------------------- */

  public async triggerSolve(draggedPointId?: number, dragTarget?: { x: number; y: number }): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.solveQueue.push({ resolve, reject, draggedPointId, dragTarget });
      if (!this.isSolving) {
        this.processSolveQueue();
      }
    });
  }

  private async processSolveQueue(): Promise<void> {
    if (this.solveQueue.length === 0) return;
    this.isSolving = true;

    const currentQueue = this.solveQueue;
    this.solveQueue = [];

    // Find the latest drag target from this batch
    let draggedPointId: number | undefined;
    let dragTarget: { x: number; y: number } | undefined;
    for (let i = currentQueue.length - 1; i >= 0; i--) {
      if (currentQueue[i].draggedPointId !== undefined) {
        draggedPointId = currentQueue[i].draggedPointId;
        dragTarget = currentQueue[i].dragTarget;
        break;
      }
    }

    try {
      const status = await this.bridge.solveSketch({
        points: this.points,
        lines: this.lines,
        arcs: this.arcs,
        circles: this.circles,
        constraints: this.constraints,
        draggedPointId,
        dragTarget,
        maxIterations: 60,
        convergenceTol: 1e-6,
      });

      // Update point positions with solved coordinates
      const coords = status.updated_coords;
      for (let i = 0; i < this.points.length; i++) {
        this.points[i].x = coords[i * 2];
        this.points[i].y = coords[i * 2 + 1];
      }

      this.solveState = status.solve_state;
      this.dof = status.degrees_of_freedom;
      this.conflictingIds = new Set(Array.from(status.conflicting_constraint_ids));

      this.renderEntities();
      this.emitState();

      for (const item of currentQueue) {
        item.resolve();
      }
    } catch (err) {
      console.error('Error during sketch solve:', err);
      for (const item of currentQueue) {
        item.reject(err);
      }
    } finally {
      this.isSolving = false;
      if (this.solveQueue.length > 0) {
        this.processSolveQueue();
      }
    }
  }

  /* ------------------------------------------------------------------------- */
  /* Entity Addition & Constraint Helpers                                      */
  /* ------------------------------------------------------------------------- */

  public addPoint(x: number, y: number, isFixed: boolean = false): CadSketchPoint2D {
    const pt: CadSketchPoint2D = {
      id: this.nextId++,
      x,
      y,
      is_fixed: isFixed ? 1 : 0,
    };
    this.points.push(pt);
    return pt;
  }

  public addLine(startPointId: number, endPointId: number): CadSketchLine2D {
    const line: CadSketchLine2D = {
      id: this.nextId++,
      start_point_id: startPointId,
      end_point_id: endPointId,
    };
    this.lines.push(line);
    return line;
  }

  public addCircle(centerPointId: number, radius: number): CadSketchCircle2D {
    const circle: CadSketchCircle2D = {
      id: this.nextId++,
      center_point_id: centerPointId,
      radius,
    };
    this.circles.push(circle);
    return circle;
  }

  public addArc(centerPointId: number, startPointId: number, endPointId: number, radius: number): CadSketchArc2D {
    const arc: CadSketchArc2D = {
      id: this.nextId++,
      center_point_id: centerPointId,
      start_point_id: startPointId,
      end_point_id: endPointId,
      radius,
    };
    this.arcs.push(arc);
    return arc;
  }

  public addConstraint(
    type: CadSketchConstraintType,
    entity1_id: number,
    entity2_id?: number,
    entity3_id?: number,
    entity4_id?: number,
    parameter_value?: number
  ): CadSketchConstraint {
    const constraint: CadSketchConstraint = {
      id: this.nextId++,
      type,
      entity1_id,
      entity2_id: entity2_id ?? CAD_SKETCH_INVALID_ID,
      entity3_id: entity3_id ?? CAD_SKETCH_INVALID_ID,
      entity4_id: entity4_id ?? CAD_SKETCH_INVALID_ID,
      parameter_value,
      is_driving: 1,
    };
    this.constraints.push(constraint);
    this.triggerSolve();
    return constraint;
  }

  public removeConstraint(constraintId: number): void {
    this.constraints = this.constraints.filter((c) => c.id !== constraintId);
    if (this.selectedConstraintId === constraintId) {
      this.selectedConstraintId = null;
    }
    this.triggerSolve();
  }

  public updateConstraintValue(constraintId: number, newValue: number): void {
    const c = this.constraints.find((item) => item.id === constraintId);
    if (c) {
      c.parameter_value = newValue;
      this.triggerSolve();
    }
  }

  /* ------------------------------------------------------------------------- */
  /* Color Coding by Degree-of-Freedom & Invariant State                       */
  /* ------------------------------------------------------------------------- */

  public getColorForEntity(id: number, type: 'point' | 'line'): number {
    // Check if selected
    if (type === 'point' && this.selectedPointIds.has(id)) return 0xf59e0b; // Yellow / Gold
    if (type === 'line' && this.selectedLineIds.has(id)) return 0xf59e0b;

    // Check solve state
    if (this.solveState === CadSolveState.CONFLICTING || this.solveState === CadSolveState.OVER_CONSTRAINED) {
      return 0xef4444; // Red (Over-constrained / Conflicting)
    }

    if (this.solveState === CadSolveState.SOLVED || this.dof === 0) {
      return 0x10b981; // Green (Fully Constrained / 0 DOF)
    }

    return 0x3b82f6; // Blue (Under-Constrained)
  }

  /* ------------------------------------------------------------------------- */
  /* Visual Rendering                                                          */
  /* ------------------------------------------------------------------------- */

  public renderEntities(): void {
    const ptLookup = new Map<number, CadSketchPoint2D>();
    for (const p of this.points) ptLookup.set(p.id, p);

    // 1. Update / Create Point Meshes (Fast in-place position updates)
    const currentPointIds = new Set<number>();
    for (const pt of this.points) {
      currentPointIds.add(pt.id);
      const pos = this.planeToWorld(pt.x, pt.y);
      const color = this.getColorForEntity(pt.id, 'point');

      let ptMesh = this.pointMeshes.get(pt.id);
      if (!ptMesh) {
        const mat = new THREE.MeshBasicMaterial({ color, depthTest: false });
        ptMesh = new THREE.Mesh(this.sharedSphereGeom, mat);
        ptMesh.renderOrder = 4;
        ptMesh.userData = { type: 'point', id: pt.id };
        this.entityGroup.add(ptMesh);
        this.pointMeshes.set(pt.id, ptMesh);
      } else {
        (ptMesh.material as THREE.MeshBasicMaterial).color.setHex(color);
      }
      ptMesh.position.copy(pos);
    }
    for (const [id, mesh] of this.pointMeshes.entries()) {
      if (!currentPointIds.has(id)) {
        this.entityGroup.remove(mesh);
        (mesh.material as THREE.Material).dispose();
        this.pointMeshes.delete(id);
      }
    }

    // 2. Update / Create Line Meshes (Fast in-place vertex coordinate updates)
    const currentLineIds = new Set<number>();
    for (const line of this.lines) {
      currentLineIds.add(line.id);
      const p1 = ptLookup.get(line.start_point_id);
      const p2 = ptLookup.get(line.end_point_id);
      if (!p1 || !p2) continue;

      const v1 = this.planeToWorld(p1.x, p1.y);
      const v2 = this.planeToWorld(p2.x, p2.y);
      const color = this.getColorForEntity(line.id, 'line');

      let lineObj = this.lineMeshes.get(line.id);
      if (!lineObj) {
        const geom = new THREE.BufferGeometry().setFromPoints([v1, v2]);
        const mat = new THREE.LineBasicMaterial({ color, linewidth: 2.5, depthTest: false });
        lineObj = new THREE.Line(geom, mat);
        lineObj.renderOrder = 3;
        lineObj.userData = { type: 'line', id: line.id };
        this.entityGroup.add(lineObj);
        this.lineMeshes.set(line.id, lineObj);
      } else {
        const posAttr = lineObj.geometry.attributes.position as THREE.BufferAttribute;
        posAttr.setXYZ(0, v1.x, v1.y, v1.z);
        posAttr.setXYZ(1, v2.x, v2.y, v2.z);
        posAttr.needsUpdate = true;
        (lineObj.material as THREE.LineBasicMaterial).color.setHex(color);
      }
    }
    for (const [id, mesh] of this.lineMeshes.entries()) {
      if (!currentLineIds.has(id)) {
        this.entityGroup.remove(mesh);
        mesh.geometry.dispose();
        (mesh.material as THREE.Material).dispose();
        this.lineMeshes.delete(id);
      }
    }

    // 3. Circles & Arcs
    const currentCircleIds = new Set<number>();
    for (const circle of this.circles) {
      currentCircleIds.add(circle.id);
      const center = ptLookup.get(circle.center_point_id);
      if (!center) continue;
      const pts: THREE.Vector3[] = [];
      const segments = 48;
      for (let i = 0; i <= segments; i++) {
        const theta = (i / segments) * Math.PI * 2;
        pts.push(this.planeToWorld(center.x + circle.radius * Math.cos(theta), center.y + circle.radius * Math.sin(theta)));
      }
      let circleObj = this.circleMeshes.get(circle.id);
      const color = this.getColorForEntity(circle.id, 'line');
      if (!circleObj) {
        const geom = new THREE.BufferGeometry().setFromPoints(pts);
        const mat = new THREE.LineBasicMaterial({ color, depthTest: false });
        circleObj = new THREE.Line(geom, mat);
        circleObj.renderOrder = 3;
        circleObj.userData = { type: 'circle', id: circle.id };
        this.entityGroup.add(circleObj);
        this.circleMeshes.set(circle.id, circleObj);
      } else {
        circleObj.geometry.setFromPoints(pts);
        (circleObj.material as THREE.LineBasicMaterial).color.setHex(color);
      }
    }
    for (const [id, mesh] of this.circleMeshes.entries()) {
      if (!currentCircleIds.has(id)) {
        this.entityGroup.remove(mesh);
        mesh.geometry.dispose();
        (mesh.material as THREE.Material).dispose();
        this.circleMeshes.delete(id);
      }
    }

    const currentArcIds = new Set<number>();
    for (const arc of this.arcs) {
      currentArcIds.add(arc.id);
      const pc = ptLookup.get(arc.center_point_id);
      const ps = ptLookup.get(arc.start_point_id);
      const pe = ptLookup.get(arc.end_point_id);
      if (!pc || !ps || !pe) continue;

      const startAngle = Math.atan2(ps.y - pc.y, ps.x - pc.x);
      let endAngle = Math.atan2(pe.y - pc.y, pe.x - pc.x);
      if (endAngle < startAngle) endAngle += Math.PI * 2;
      const pts: THREE.Vector3[] = [];
      const segments = 32;
      for (let i = 0; i <= segments; i++) {
        const theta = startAngle + (i / segments) * (endAngle - startAngle);
        pts.push(this.planeToWorld(pc.x + arc.radius * Math.cos(theta), pc.y + arc.radius * Math.sin(theta)));
      }
      let arcObj = this.arcMeshes.get(arc.id);
      const color = this.getColorForEntity(arc.id, 'line');
      if (!arcObj) {
        const geom = new THREE.BufferGeometry().setFromPoints(pts);
        const mat = new THREE.LineBasicMaterial({ color, depthTest: false });
        arcObj = new THREE.Line(geom, mat);
        arcObj.renderOrder = 3;
        arcObj.userData = { type: 'arc', id: arc.id };
        this.entityGroup.add(arcObj);
        this.arcMeshes.set(arc.id, arcObj);
      } else {
        arcObj.geometry.setFromPoints(pts);
        (arcObj.material as THREE.LineBasicMaterial).color.setHex(color);
      }
    }
    for (const [id, mesh] of this.arcMeshes.entries()) {
      if (!currentArcIds.has(id)) {
        this.entityGroup.remove(mesh);
        mesh.geometry.dispose();
        (mesh.material as THREE.Material).dispose();
        this.arcMeshes.delete(id);
      }
    }

    // 4. Overlays & Dimension Sprites
    while (this.overlayGroup.children.length > 0) {
      const child = this.overlayGroup.children.pop()!;
      if ((child as any).geometry) (child as any).geometry.dispose();
      if ((child as any).material) {
        if ((child as any).material.map) (child as any).material.map.dispose();
        (child as any).material.dispose();
      }
    }

    for (const line of this.lines) {
      const p1 = ptLookup.get(line.start_point_id);
      const p2 = ptLookup.get(line.end_point_id);
      if (p1 && p2) this.renderLineConstraintGlyphs(line, p1, p2);
    }
    this.renderDimensionalConstraints(ptLookup);
  }

  private renderLineConstraintGlyphs(line: CadSketchLine2D, p1: CadSketchPoint2D, p2: CadSketchPoint2D): void {
    const midU = (p1.x + p2.x) / 2;
    const midV = (p1.y + p2.y) / 2;
    const lineConstraints = this.constraints.filter(
      (c) => c.entity1_id === line.id || c.entity2_id === line.id
    );

    for (const c of lineConstraints) {
      let glyph = '';
      if (c.type === CadSketchConstraintType.HORIZONTAL) glyph = '—';
      else if (c.type === CadSketchConstraintType.VERTICAL) glyph = '|';
      else if (c.type === CadSketchConstraintType.PARALLEL) glyph = '//';
      else if (c.type === CadSketchConstraintType.PERPENDICULAR) glyph = '⊥';
      else if (c.type === CadSketchConstraintType.EQUAL) glyph = '=';

      if (glyph) {
        const sprite = this.createGlyphSprite(glyph, 0x93c5fd);
        sprite.position.copy(this.planeToWorld(midU, midV + 0.25));
        sprite.scale.set(0.6, 0.6, 1);
        sprite.renderOrder = 5;
        this.overlayGroup.add(sprite);
      }
    }
  }

  private renderDimensionalConstraints(ptLookup: Map<number, CadSketchPoint2D>): void {
    const dimConstraints = this.constraints.filter(
      (c) =>
        c.type === CadSketchConstraintType.DISTANCE ||
        c.type === CadSketchConstraintType.RADIUS ||
        c.type === CadSketchConstraintType.ANGLE
    );

    for (const c of dimConstraints) {
      let text = '';
      let posU = 0;
      let posV = 0;

      if (c.type === CadSketchConstraintType.DISTANCE) {
        text = `${(c.parameter_value ?? 0).toFixed(2)} mm`;
        const line = this.lines.find((l) => l.id === c.entity1_id);
        if (line) {
          const p1 = ptLookup.get(line.start_point_id);
          const p2 = ptLookup.get(line.end_point_id);
          if (p1 && p2) {
            posU = (p1.x + p2.x) / 2;
            posV = (p1.y + p2.y) / 2 + 0.35;
          }
        } else if (c.entity2_id !== undefined && c.entity2_id !== CAD_SKETCH_INVALID_ID) {
          const p1 = ptLookup.get(c.entity1_id);
          const p2 = ptLookup.get(c.entity2_id);
          if (p1 && p2) {
            posU = (p1.x + p2.x) / 2;
            posV = (p1.y + p2.y) / 2 + 0.35;
          }
        }
      } else if (c.type === CadSketchConstraintType.RADIUS) {
        text = `R ${(c.parameter_value ?? 0).toFixed(2)}`;
        const arc = this.arcs.find((a) => a.id === c.entity1_id);
        const circle = this.circles.find((ci) => ci.id === c.entity1_id);
        const centerId = arc ? arc.center_point_id : (circle ? circle.center_point_id : undefined);
        if (centerId !== undefined) {
          const pc = ptLookup.get(centerId);
          if (pc) {
            posU = pc.x;
            posV = pc.y + (c.parameter_value ?? 1.0) + 0.25;
          }
        }
      } else if (c.type === CadSketchConstraintType.ANGLE) {
        const deg = ((c.parameter_value ?? 0) * 180) / Math.PI;
        text = `${deg.toFixed(1)}°`;
        const l1 = this.lines.find((l) => l.id === c.entity1_id);
        if (l1) {
          const p1 = ptLookup.get(l1.start_point_id);
          if (p1) {
            posU = p1.x + 0.3;
            posV = p1.y + 0.3;
          }
        }
      }

      if (text) {
        const isConflicting = this.conflictingIds.has(c.id);
        const color = isConflicting ? 0xef4444 : 0x38bdf8;
        const sprite = this.createDimensionSprite(text, color, c.id);
        sprite.position.copy(this.planeToWorld(posU, posV));
        sprite.scale.set(1.5, 0.6, 1);
        sprite.renderOrder = 6;
        sprite.userData = { type: 'constraint', id: c.id };
        this.overlayGroup.add(sprite);
      }
    }
  }

  private createGlyphSprite(glyph: string, colorHex: number): THREE.Sprite {
    const canvas = document.createElement('canvas');
    canvas.width = 64;
    canvas.height = 64;
    const ctx = canvas.getContext('2d')!;
    ctx.fillStyle = `#${colorHex.toString(16).padStart(6, '0')}`;
    ctx.font = 'bold 36px monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(glyph, 32, 32);

    const texture = new THREE.CanvasTexture(canvas);
    const mat = new THREE.SpriteMaterial({ map: texture, depthTest: false });
    return new THREE.Sprite(mat);
  }

  private createDimensionSprite(text: string, colorHex: number, constraintId: number): THREE.Sprite {
    const canvas = document.createElement('canvas');
    canvas.width = 160;
    canvas.height = 64;
    const ctx = canvas.getContext('2d')!;

    // Rounded tag background
    ctx.fillStyle = 'rgba(15, 23, 42, 0.85)';
    ctx.strokeStyle = `#${colorHex.toString(16).padStart(6, '0')}`;
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.roundRect(4, 8, 152, 48, 8);
    ctx.fill();
    ctx.stroke();

    ctx.fillStyle = '#f8fafc';
    ctx.font = 'bold 22px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, 80, 32);

    const texture = new THREE.CanvasTexture(canvas);
    const mat = new THREE.SpriteMaterial({ map: texture, depthTest: false });
    const sprite = new THREE.Sprite(mat);
    sprite.userData = { type: 'constraint', id: constraintId };
    return sprite;
  }

  /* ------------------------------------------------------------------------- */
  /* Tool Previews & Snap Overlays                                             */
  /* ------------------------------------------------------------------------- */

  private updatePreview(u: number, v: number): void {
    // Clear preview group
    while (this.previewGroup.children.length > 0) {
      const child = this.previewGroup.children.pop()!;
      if ((child as any).geometry) (child as any).geometry.dispose();
      if ((child as any).material) (child as any).material.dispose();
    }

    // 1. Draw Snap Indicator
    if (this.tools.snapTarget) {
      const snapWorld = this.planeToWorld(this.tools.snapTarget.u, this.tools.snapTarget.v);
      const ringGeom = new THREE.RingGeometry(0.18, 0.24, 24);
      const ringMat = new THREE.MeshBasicMaterial({
        color: 0x38bdf8,
        side: THREE.DoubleSide,
        depthTest: false,
      });
      const snapRing = new THREE.Mesh(ringGeom, ringMat);
      snapRing.position.copy(snapWorld);
      snapRing.renderOrder = 7;
      this.previewGroup.add(snapRing);
    }

    // 2. Draw Inference Glyph (Horizontal / Vertical line preview)
    if (this.tools.inference.type !== 'none') {
      const start = this.tools.getStartPoint();
      if (start) {
        const p1 = this.planeToWorld(start.u, start.v);
        const p2 = this.planeToWorld(this.tools.inference.u, this.tools.inference.v);
        const geom = new THREE.BufferGeometry().setFromPoints([p1, p2]);
        const mat = new THREE.LineDashedMaterial({
          color: 0xfacc15,
          dashSize: 0.2,
          gapSize: 0.1,
          depthTest: false,
        });
        const infLine = new THREE.Line(geom, mat);
        infLine.computeLineDistances();
        infLine.renderOrder = 7;
        this.previewGroup.add(infLine);

        const glyphStr = this.tools.inference.type === 'horizontal' ? '—' : '|';
        const glyph = this.createGlyphSprite(glyphStr, 0xfacc15);
        glyph.position.copy(this.planeToWorld(u, v + 0.3));
        glyph.scale.set(0.6, 0.6, 1);
        glyph.renderOrder = 8;
        this.previewGroup.add(glyph);
      }
    }

    // 3. Draw Rubber-band previews for active tool
    const tool = this.tools.activeTool;
    const start = this.tools.getStartPoint();

    if (tool === 'line' && start) {
      const targetU = this.tools.inference.type !== 'none' ? this.tools.inference.u : u;
      const targetV = this.tools.inference.type !== 'none' ? this.tools.inference.v : v;
      const p1 = this.planeToWorld(start.u, start.v);
      const p2 = this.planeToWorld(targetU, targetV);
      const geom = new THREE.BufferGeometry().setFromPoints([p1, p2]);
      const mat = new THREE.LineBasicMaterial({
        color: 0x60a5fa,
        depthTest: false,
      });
      const previewLine = new THREE.Line(geom, mat);
      previewLine.renderOrder = 7;
      this.previewGroup.add(previewLine);
    } else if (tool === 'rectangle' && start) {
      const p1 = this.planeToWorld(start.u, start.v);
      const p2 = this.planeToWorld(u, start.v);
      const p3 = this.planeToWorld(u, v);
      const p4 = this.planeToWorld(start.u, v);
      const geom = new THREE.BufferGeometry().setFromPoints([p1, p2, p3, p4, p1]);
      const mat = new THREE.LineBasicMaterial({
        color: 0x60a5fa,
        depthTest: false,
      });
      const previewRect = new THREE.Line(geom, mat);
      previewRect.renderOrder = 7;
      this.previewGroup.add(previewRect);
    } else if (tool === 'circle' && start) {
      const r = Math.hypot(u - start.u, v - start.v);
      const pts: THREE.Vector3[] = [];
      const segments = 48;
      for (let i = 0; i <= segments; i++) {
        const theta = (i / segments) * Math.PI * 2;
        pts.push(this.planeToWorld(start.u + r * Math.cos(theta), start.v + r * Math.sin(theta)));
      }
      const geom = new THREE.BufferGeometry().setFromPoints(pts);
      const mat = new THREE.LineBasicMaterial({
        color: 0x60a5fa,
        depthTest: false,
      });
      const previewCirc = new THREE.Line(geom, mat);
      previewCirc.renderOrder = 7;
      this.previewGroup.add(previewCirc);
    }
  }

  /* ------------------------------------------------------------------------- */
  /* Pointer Event Handling                                                    */
  /* ------------------------------------------------------------------------- */

  private setupListeners(): void {
    this.canvas.addEventListener('pointerdown', (e) => {
      if (!this.inSketchMode) return;
      this.isPointerDown = true;
      this.pointerDownClient = { x: e.clientX, y: e.clientY };

      const coords = this.raycastPlane(e.clientX, e.clientY);
      if (!coords) return;

      if (this.tools.activeTool === 'select') {
        // Check hit testing for points or constraints
        const hit = this.pickSketchEntity(e.clientX, e.clientY);
        if (hit?.type === 'point') {
          this.draggingPointId = hit.id;
        } else if (hit?.type === 'constraint') {
          const c = this.constraints.find((item) => item.id === hit.id);
          if (c && this.onRequestDimensionEdit) {
            this.onRequestDimensionEdit(c, e.clientX, e.clientY);
          }
        }
      }
    });

    this.canvas.addEventListener('pointermove', (e) => {
      if (!this.inSketchMode) return;

      const coords = this.raycastPlane(e.clientX, e.clientY);
      if (!coords) return;

      let effectiveU = coords.u;
      let effectiveV = coords.v;

      // Handle live point dragging in Select mode
      if (this.isPointerDown && this.draggingPointId !== null && this.tools.activeTool === 'select') {
        const pt = this.points.find((p) => p.id === this.draggingPointId);
        if (pt && !pt.is_fixed) {
          // Instant live solve update while maintaining 60 FPS
          this.triggerSolve(this.draggingPointId, { x: effectiveU, y: effectiveV });
        }
        return;
      }

      // Compute magnetic snap
      const snap = this.tools.computeSnap(effectiveU, effectiveV, this.points, true);
      this.tools.snapTarget = snap;
      if (snap) {
        effectiveU = snap.u;
        effectiveV = snap.v;
      }

      // Compute automatic inference glyphs
      const start = this.tools.getStartPoint();
      if (start && this.tools.activeTool === 'line') {
        this.tools.inference = this.tools.computeInference(start.u, start.v, effectiveU, effectiveV);
      } else {
        this.tools.inference = { type: 'none', u: effectiveU, v: effectiveV };
      }

      this.updatePreview(effectiveU, effectiveV);

      if (this.onCoordinateChange) {
        this.onCoordinateChange(effectiveU, effectiveV);
      }
    });

    this.canvas.addEventListener('pointerup', (e) => {
      if (!this.inSketchMode) return;
      const dx = Math.abs(e.clientX - this.pointerDownClient.x);
      const dy = Math.abs(e.clientY - this.pointerDownClient.y);
      this.isPointerDown = false;

      if (this.draggingPointId !== null) {
        this.draggingPointId = null;
        return;
      }

      // If it was a click (not drag)
      if (dx <= 4 && dy <= 4) {
        this.handleClick(e.clientX, e.clientY);
      }
    });
  }

  private pickSketchEntity(clientX: number, clientY: number): { type: string; id: number } | null {
    const rect = this.canvas.getBoundingClientRect();
    this.mouse.x = ((clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((clientY - rect.top) / rect.height) * 2 + 1;

    this.raycaster.setFromCamera(this.mouse, this.camera);
    const intersects = this.raycaster.intersectObjects(this.entityGroup.children, true);

    for (const hit of intersects) {
      if (hit.object.userData && hit.object.userData.type) {
        return {
          type: hit.object.userData.type,
          id: hit.object.userData.id,
        };
      }
    }
    return null;
  }

  private handleClick(clientX: number, clientY: number): void {
    const coords = this.raycastPlane(clientX, clientY);
    if (!coords) return;

    let u = coords.u;
    let v = coords.v;

    if (this.tools.snapTarget) {
      u = this.tools.snapTarget.u;
      v = this.tools.snapTarget.v;
    }

    const tool = this.tools.activeTool;

    if (tool === 'select') {
      const hit = this.pickSketchEntity(clientX, clientY);
      if (hit?.type === 'point') {
        if (this.selectedPointIds.has(hit.id)) {
          this.selectedPointIds.delete(hit.id);
        } else {
          this.selectedPointIds.add(hit.id);
        }
      } else if (hit?.type === 'line') {
        if (this.selectedLineIds.has(hit.id)) {
          this.selectedLineIds.delete(hit.id);
        } else {
          this.selectedLineIds.add(hit.id);
        }
      } else {
        // Clicked empty area: clear selection
        this.selectedPointIds.clear();
        this.selectedLineIds.clear();
        this.selectedArcIds.clear();
        this.selectedCircleIds.clear();
      }
      this.renderEntities();
      this.emitState();
      return;
    }

    if (tool === 'line') {
      const start = this.tools.getStartPoint();
      if (!start) {
        // Step 1: Start point
        let ptId = this.tools.snapTarget?.type === 'point' ? this.tools.snapTarget.pointId : undefined;
        if (ptId === undefined) {
          const pt = this.addPoint(u, v);
          ptId = pt.id;
        }
        this.tools.setStartPoint({ u, v, pointId: ptId });
      } else {
        // Step 2: End point
        let targetU = u;
        let targetV = v;
        const inf = this.tools.inference;
        if (inf.type !== 'none') {
          targetU = inf.u;
          targetV = inf.v;
        }

        let endPtId = this.tools.snapTarget?.type === 'point' ? this.tools.snapTarget.pointId : undefined;
        if (endPtId === undefined) {
          const pt = this.addPoint(targetU, targetV);
          endPtId = pt.id;
        }

        const newLine = this.addLine(start.pointId!, endPtId);

        // Apply automatic horizontal/vertical inference constraint
        if (inf.type === 'horizontal') {
          this.addConstraint(CadSketchConstraintType.HORIZONTAL, newLine.id);
        } else if (inf.type === 'vertical') {
          this.addConstraint(CadSketchConstraintType.VERTICAL, newLine.id);
        }

        this.tools.reset();
        this.triggerSolve();
      }
    } else if (tool === 'rectangle') {
      const start = this.tools.getStartPoint();
      if (!start) {
        this.tools.setStartPoint({ u, v });
      } else {
        // Create 4 corners
        const p1 = this.addPoint(start.u, start.v);
        const p2 = this.addPoint(u, start.v);
        const p3 = this.addPoint(u, v);
        const p4 = this.addPoint(start.u, v);

        // Create 4 lines
        const l1 = this.addLine(p1.id, p2.id); // bottom
        const l2 = this.addLine(p2.id, p3.id); // right
        const l3 = this.addLine(p3.id, p4.id); // top
        const l4 = this.addLine(p4.id, p1.id); // left

        // Add horizontal and vertical constraints
        this.addConstraint(CadSketchConstraintType.HORIZONTAL, l1.id);
        this.addConstraint(CadSketchConstraintType.VERTICAL, l2.id);
        this.addConstraint(CadSketchConstraintType.HORIZONTAL, l3.id);
        this.addConstraint(CadSketchConstraintType.VERTICAL, l4.id);

        this.tools.reset();
        this.triggerSolve();
      }
    } else if (tool === 'circle') {
      const start = this.tools.getStartPoint();
      if (!start) {
        let centerId = this.tools.snapTarget?.type === 'point' ? this.tools.snapTarget.pointId : undefined;
        if (centerId === undefined) {
          const pt = this.addPoint(u, v);
          centerId = pt.id;
        }
        this.tools.setStartPoint({ u, v, pointId: centerId });
      } else {
        const radius = Math.hypot(u - start.u, v - start.v);
        this.addCircle(start.pointId!, Math.max(0.2, radius));
        this.tools.reset();
        this.triggerSolve();
      }
    } else if (tool === 'arc') {
      const step = this.tools.getStep();
      if (step === 0) {
        let centerId = this.tools.snapTarget?.type === 'point' ? this.tools.snapTarget.pointId : undefined;
        if (centerId === undefined) {
          const pt = this.addPoint(u, v);
          centerId = pt.id;
        }
        this.tools.setStartPoint({ u, v, pointId: centerId });
      } else if (step === 1) {
        const pStart = this.addPoint(u, v);
        this.tools.setIntermediatePoint({ u, v, pointId: pStart.id });
      } else {
        const center = this.tools.getStartPoint()!;
        const startPt = this.tools.getIntermediatePoint()!;
        const radius = Math.hypot(startPt.u - center.u, startPt.v - center.v);
        const pEnd = this.addPoint(u, v);
        this.addArc(center.pointId!, startPt.pointId!, pEnd.id, radius);
        this.tools.reset();
        this.triggerSolve();
      }
    }
  }

  /* ------------------------------------------------------------------------- */
  /* State Emitter                                                             */
  /* ------------------------------------------------------------------------- */

  private emitState(): void {
    if (this.onStateChange) {
      this.onStateChange({
        inSketchMode: this.inSketchMode,
        activePlane: this.activePlane,
        activeTool: this.tools.activeTool,
        dof: this.dof,
        solveState: this.solveState,
        pointCount: this.points.length,
        lineCount: this.lines.length,
        arcCount: this.arcs.length,
        circleCount: this.circles.length,
        constraintCount: this.constraints.length,
        selectedEntityIds: {
          points: Array.from(this.selectedPointIds),
          lines: Array.from(this.selectedLineIds),
          arcs: Array.from(this.selectedArcIds),
          circles: Array.from(this.selectedCircleIds),
        },
        selectedConstraintId: this.selectedConstraintId,
      });
    }
  }
}

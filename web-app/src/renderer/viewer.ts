import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { CadMeshRawBuffers, CadTessellatedSolidSlice, SubShapeSelection, VisualDiffData } from '../types/cad';
import { CadWorkerBridge } from '../worker/worker_bridge';
import { FpsCounter } from './fps_counter';
import { MeshManager } from './mesh_manager';
import { CadPicker } from './picker';
import { DatumPlane, SketchManager } from './sketch_manager';

export interface ViewerOptions {
  canvas: HTMLCanvasElement;
  bridge: CadWorkerBridge;
  onSelectionChange?: (selection: SubShapeSelection) => void;
  onFpsUpdate?: (fps: number, frameTimeMs: number) => void;
}

export class CadViewer {
  public canvas: HTMLCanvasElement;
  public renderer: THREE.WebGLRenderer;
  public scene: THREE.Scene;
  public camera: THREE.PerspectiveCamera;
  public controls: OrbitControls;
  public bridge: CadWorkerBridge;

  public meshManager: MeshManager;
  public picker: CadPicker;
  public fpsCounter: FpsCounter;
  public sketchManager: SketchManager;

  private isRunning: boolean = false;
  private animFrameId: number | null = null;
  private onSelectionChange?: (selection: SubShapeSelection) => void;
  private onFpsUpdate?: (fps: number, frameTimeMs: number) => void;
  private lastFpsUpdateTime: number = 0;

  public currentSelection: SubShapeSelection = { type: 'none' };
  public hoveredSelection: SubShapeSelection = { type: 'none' };

  private isPointerDown: boolean = false;
  private pointerDownPos: { x: number; y: number } = { x: 0, y: 0 };
  public totalFrameCount: number = 0;
  public frameTimestamps: number[] = [];

  constructor(options: ViewerOptions) {
    this.canvas = options.canvas;
    this.bridge = options.bridge;
    this.onSelectionChange = options.onSelectionChange;
    this.onFpsUpdate = options.onFpsUpdate;

    // 1. Initialize Renderer
    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      powerPreference: 'high-performance',
      alpha: false,
      preserveDrawingBuffer: true,
    });
    this.renderer.setSize(this.canvas.clientWidth, this.canvas.clientHeight, false);
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.setClearColor(0x121316, 1.0); // Neutral dark slate canvas background

    // 2. Initialize Scene
    this.scene = new THREE.Scene();

    // 3. Initialize Camera (Isometric 3D CAD view with +Z up, matching Fabify view-3d)
    const aspect = this.canvas.clientWidth / Math.max(1, this.canvas.clientHeight);
    this.camera = new THREE.PerspectiveCamera(35, aspect, 0.01, 2000);
    this.camera.up.set(0, 0, 1);
    this.camera.position.set(100, 100, 100);
    this.camera.lookAt(0, 0, 0);

    // 4. Initialize Orbit Controls
    this.controls = new OrbitControls(this.camera, this.canvas);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;
    this.controls.target.set(0, 0, 0);

    // 5. Lighting Setup (Multi-point balanced studio lighting)
    const ambientLight = new THREE.AmbientLight(0xffffff, 0.65);
    this.scene.add(ambientLight);

    const hemiLight = new THREE.HemisphereLight(0xE6EDF3, 0x121316, 0.45);
    hemiLight.position.set(0, 20, 0);
    this.scene.add(hemiLight);

    const keyLight = new THREE.DirectionalLight(0xffffff, 1.2);
    keyLight.position.set(10, 15, 12);
    this.scene.add(keyLight);

    const fillLight = new THREE.DirectionalLight(0x8B949E, 0.5);
    fillLight.position.set(-10, 10, -10);
    this.scene.add(fillLight);

    const backLight = new THREE.DirectionalLight(0xffffff, 0.4);
    backLight.position.set(0, -10, -10);
    this.scene.add(backLight);

    // 6. CAD Model Root MeshManager & Picker (No floor grid; clean, elegant normal rendering)
    this.meshManager = new MeshManager();
    this.scene.add(this.meshManager.group);

    this.picker = new CadPicker(this.camera, this.canvas, this.meshManager);
    this.fpsCounter = new FpsCounter(60);

    // 8. Initialize 2D Sketch Manager
    this.sketchManager = new SketchManager(
      this.scene,
      this.camera,
      this.canvas,
      this.controls,
      this.bridge
    );

    // 9. Event Listeners
    this.setupEventListeners();

    // 10. Start Rendering Loop
    this.start();
  }

  private setupEventListeners(): void {
    window.addEventListener('resize', this.handleResize.bind(this));

    this.canvas.addEventListener('pointerdown', (e) => {
      if (this.sketchManager.inSketchMode) return;
      this.isPointerDown = true;
      this.pointerDownPos = { x: e.clientX, y: e.clientY };
    });

    this.canvas.addEventListener('pointermove', (e) => {
      if (this.sketchManager.inSketchMode) return;
      // If user is dragging orbit controls, do not pick
      if (this.isPointerDown) {
        const dx = Math.abs(e.clientX - this.pointerDownPos.x);
        const dy = Math.abs(e.clientY - this.pointerDownPos.y);
        if (dx > 4 || dy > 4) return;
      }

      // Hover picking
      const pick = this.picker.pickClient(e.clientX, e.clientY);
      this.hoveredSelection = pick;

      // Update hover highlight if not locked by active selection
      if (this.currentSelection.type === 'none') {
        if (pick.type === 'face') {
          this.meshManager.setHighlightedFace(pick.topoId ?? pick.faceId);
          this.meshManager.setHighlightedEdge(null);
        } else if (pick.type === 'edge') {
          this.meshManager.setHighlightedEdge(pick.topoId ?? pick.edgeId);
          this.meshManager.setHighlightedFace(null);
        } else {
          this.meshManager.setHighlightedFace(null);
          this.meshManager.setHighlightedEdge(null);
        }
      }
    });

    this.canvas.addEventListener('pointerup', (e) => {
      if (this.sketchManager.inSketchMode) return;
      if (this.isPointerDown) {
        const dx = Math.abs(e.clientX - this.pointerDownPos.x);
        const dy = Math.abs(e.clientY - this.pointerDownPos.y);
        this.isPointerDown = false;

        // If it was a click (not an orbit drag), perform selection
        if (dx <= 4 && dy <= 4) {
          const selection = this.picker.pickClient(e.clientX, e.clientY);
          this.setSelection(selection);
        }
      }
    });
  }

  public setSelection(selection: SubShapeSelection): void {
    this.currentSelection = selection;

    if (selection.type === 'face') {
      this.meshManager.setHighlightedFace(selection.topoId ?? selection.faceId);
      this.meshManager.setHighlightedEdge(null);
    } else if (selection.type === 'edge') {
      this.meshManager.setHighlightedEdge(selection.topoId ?? selection.edgeId);
      this.meshManager.setHighlightedFace(null);
    } else {
      this.meshManager.setHighlightedFace(null);
      this.meshManager.setHighlightedEdge(null);
    }

    if (this.onSelectionChange) {
      this.onSelectionChange(selection);
    }
  }

  public setGeometry(buffers: CadMeshRawBuffers): void {
    this.meshManager.updateGeometry(buffers);
    this.fitCameraToMesh(true);
    this.setSelection({ type: 'none' });
  }

  public setGeometryFromSlice(slice: CadTessellatedSolidSlice): void {
    this.meshManager.updateFromSlice(slice);
    this.fitCameraToMesh(true);
    this.setSelection({ type: 'none' });
  }

  public updateAssembly(
    transforms: Float32Array,
    instanceCount: number,
    baseGeometry?: THREE.BufferGeometry
  ): void {
    this.meshManager.updateAssemblyInstances(transforms, instanceCount, baseGeometry);
    this.setSelection({ type: 'none' });
  }

  public updateLodGeometries(
    coarseGeom: THREE.BufferGeometry,
    mediumGeom: THREE.BufferGeometry,
    fineGeom: THREE.BufferGeometry
  ): void {
    this.meshManager.updateLOD(coarseGeom, mediumGeom, fineGeom);
    this.setSelection({ type: 'none' });
  }

  public setVisualDiff(diff: VisualDiffData | null): void {
    this.meshManager.setVisualDiff(diff);
  }

  public setInspectionMode(mode: 'standard' | 'zebra' | 'curvature' | 'draft'): void {
    this.meshManager.setInspectionMode(mode);
  }

  public clippingPlane: THREE.Plane = new THREE.Plane(new THREE.Vector3(0, 0, 1), 0);
  public isSectionPlaneEnabled: boolean = false;
  public explodeFactor: number = 0.0;

  public enableSectionPlane(enabled: boolean, normal = new THREE.Vector3(0, 0, 1), constant = 0): void {
    this.isSectionPlaneEnabled = enabled;
    this.renderer.localClippingEnabled = enabled;
    this.clippingPlane.normal.copy(normal).normalize();
    this.clippingPlane.constant = constant;
    this.renderer.clippingPlanes = enabled ? [this.clippingPlane] : [];
  }

  public setSectionPlaneConstant(constant: number): void {
    this.clippingPlane.constant = constant;
  }

  public setExplodeFactor(factor: number): void {
    this.explodeFactor = factor;
    // Displace root mesh objects if assembly instances are present
    const solidMesh = this.meshManager.solidMesh;
    if (solidMesh) {
      solidMesh.position.set(0, 0, factor * 2.0);
    }
  }

  public setAssemblyMotionAngle(angleDeg: number): void {
    const rad = (angleDeg * Math.PI) / 180;
    if (this.meshManager.solidMesh) {
      this.meshManager.solidMesh.rotation.y = rad;
    }
  }

  public getFps(): number {
    return this.fpsCounter.getFps();
  }

  public getTriangleCount(): number {
    return this.meshManager.getTriangleCount();
  }

  private hasInitialCameraFit: boolean = false;

  public fitCameraToMesh(force: boolean = true): void {
    const geom = this.meshManager.solidMesh.geometry;
    if (!geom || !geom.attributes.position || geom.attributes.position.count === 0) return;

    if (!force && this.hasInitialCameraFit) return;

    geom.computeBoundingBox();
    const bbox = geom.boundingBox;
    if (!bbox) return;

    const center = new THREE.Vector3();
    bbox.getCenter(center);
    const size = new THREE.Vector3();
    bbox.getSize(size);

    // Compute bounding box diagonal: r = sqrt(x^2 + y^2 + z^2)
    const diag = Math.sqrt(size.x * size.x + size.y * size.y + size.z * size.z);
    if (diag <= 0) return;

    // Center model's bounding box at origin (0, 0, 0)
    this.meshManager.group.position.set(-center.x, -center.y, -center.z);
    this.meshManager.group.updateMatrixWorld(true);

    // Constant relative ratio of bounding box diagonal (Fabify view-3d: d = (diag / 2) * tan(pi / 2.65))
    const d = (diag / 2) * Math.tan(Math.PI / 2.65);
    const camDist = d * 1.4; // constant relative ratio ~3.0x - 3.5x diagonal

    this.camera.up.set(0, 0, 1);
    this.camera.position.set(camDist, camDist, camDist);
    this.controls.target.set(0, 0, 0);
    this.camera.lookAt(0, 0, 0);
    this.camera.near = Math.max(0.01, camDist / 1000);
    this.camera.far = Math.max(2000, camDist * 8);
    this.controls.update();
    this.camera.updateProjectionMatrix();

    this.hasInitialCameraFit = true;
  }

  public captureScreenshot(viewAngle: 'current' | 'front' | 'top' | 'isometric' = 'current'): string {
    const originalPos = this.camera.position.clone();
    const originalTarget = this.controls.target.clone();

    if (viewAngle === 'front') {
      this.camera.position.set(0, -150, 0);
      this.camera.up.set(0, 0, 1);
      this.camera.lookAt(0, 0, 0);
    } else if (viewAngle === 'top') {
      this.camera.position.set(0, 0, 150);
      this.camera.up.set(0, 1, 0);
      this.camera.lookAt(0, 0, 0);
    } else if (viewAngle === 'isometric') {
      const d = 120;
      this.camera.up.set(0, 0, 1);
      this.camera.position.set(d, d, d);
      this.camera.lookAt(0, 0, 0);
    }
    this.camera.updateProjectionMatrix();
    this.renderer.render(this.scene, this.camera);
    const dataUrl = this.canvas.toDataURL('image/png');

    if (viewAngle !== 'current') {
      this.camera.position.copy(originalPos);
      this.controls.target.copy(originalTarget);
      this.camera.lookAt(originalTarget);
      this.camera.updateProjectionMatrix();
      this.renderer.render(this.scene, this.camera);
    }
    return dataUrl;
  }

  public enterSketchMode(plane: DatumPlane = 'XY'): void {
    this.setSelection({ type: 'none' });
    this.sketchManager.enterSketchMode(plane);
  }

  public exitSketchMode(): void {
    this.sketchManager.exitSketchMode();
  }

  public handleResize(): void {
    const width = this.canvas.clientWidth;
    const height = this.canvas.clientHeight;
    if (width === 0 || height === 0) return;

    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(width, height, false);
  }

  public start(): void {
    if (this.isRunning) return;
    this.isRunning = true;

    const renderLoop = (time: number) => {
      if (!this.isRunning) return;

      this.fpsCounter.tick(time);
      this.totalFrameCount++;
      this.frameTimestamps.push(time);
      if (this.frameTimestamps.length > 200) {
        this.frameTimestamps.shift();
      }

      // Update HUD FPS every 100ms to avoid DOM thrashing
      if (time - this.lastFpsUpdateTime > 100) {
        this.lastFpsUpdateTime = time;
        if (this.onFpsUpdate) {
          this.onFpsUpdate(this.fpsCounter.getFps(), this.fpsCounter.getFrameTimeMs());
        }
      }

      this.controls.update();
      if (!(window as any).__cadBusy) {
        this.renderer.render(this.scene, this.camera);
      }

      this.animFrameId = requestAnimationFrame(renderLoop);
    };

    this.animFrameId = requestAnimationFrame(renderLoop);
  }

  public stop(): void {
    this.isRunning = false;
    if (this.animFrameId !== null) {
      cancelAnimationFrame(this.animFrameId);
      this.animFrameId = null;
    }
  }

  public dispose(): void {
    this.stop();
    this.controls.dispose();
    this.renderer.dispose();
  }
}

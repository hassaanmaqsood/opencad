import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { CadMeshRawBuffers, CadTessellatedSolidSlice, SubShapeSelection } from '../types/cad';
import type { VisualDiffData } from '../core-shell/PluginTypes';
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
    });
    this.renderer.setSize(this.canvas.clientWidth, this.canvas.clientHeight, false);
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.setClearColor(0x181a1f, 1.0); // CAD dark graphite background

    // 2. Initialize Scene
    this.scene = new THREE.Scene();

    // 3. Initialize Camera (Isometric 3D CAD view)
    const aspect = this.canvas.clientWidth / Math.max(1, this.canvas.clientHeight);
    this.camera = new THREE.PerspectiveCamera(45, aspect, 0.1, 1000);
    this.camera.position.set(6, 6, 8);
    this.camera.lookAt(0, 0, 0);

    // 4. Initialize Orbit Controls
    this.controls = new OrbitControls(this.camera, this.canvas);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;
    this.controls.target.set(0, 0, 0);

    // 5. Lighting Setup (Multi-point balanced studio lighting)
    const ambientLight = new THREE.AmbientLight(0xffffff, 0.65);
    this.scene.add(ambientLight);

    const hemiLight = new THREE.HemisphereLight(0xe2e8f0, 0x1e293b, 0.45);
    hemiLight.position.set(0, 20, 0);
    this.scene.add(hemiLight);

    const keyLight = new THREE.DirectionalLight(0xffffff, 1.2);
    keyLight.position.set(10, 15, 12);
    this.scene.add(keyLight);

    const fillLight = new THREE.DirectionalLight(0x93c5fd, 0.6);
    fillLight.position.set(-10, 10, -10);
    this.scene.add(fillLight);

    const backLight = new THREE.DirectionalLight(0xffffff, 0.4);
    backLight.position.set(0, -10, -10);
    this.scene.add(backLight);

    // 6. CAD Floor Grid & Orientation Helpers
    const gridHelper = new THREE.GridHelper(20, 40, 0x3b82f6, 0x334155);
    gridHelper.position.y = -0.001; // prevent z-fighting
    (gridHelper.material as THREE.Material).transparent = true;
    (gridHelper.material as THREE.Material).opacity = 0.4;
    this.scene.add(gridHelper);

    const axesHelper = new THREE.AxesHelper(2.5);
    (axesHelper.material as THREE.Material).depthTest = false;
    axesHelper.renderOrder = 1;
    this.scene.add(axesHelper);

    // 7. Initialize MeshManager & Picker
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
    this.setSelection({ type: 'none' });
  }

  public setGeometryFromSlice(slice: CadTessellatedSolidSlice): void {
    this.meshManager.updateFromSlice(slice);
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
      this.renderer.render(this.scene, this.camera);

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

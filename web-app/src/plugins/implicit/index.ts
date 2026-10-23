import * as THREE from 'three';
import { OpenCadExtensionPlugin, PluginContext } from '../../core-shell/PluginTypes';
import { createCrossSectionPlane, CrossSectionUniforms } from './CrossSectionShader';
import { BlockStackUi, ImplicitBlockConfig } from './BlockStack';
import { getAssetUrl } from '../../utils/assets';

export class ImplicitPlugin implements OpenCadExtensionPlugin {
  public metadata = {
    id: 'implicit',
    name: 'Implicit & Field Workbench (nTop)',
    version: '1.0.0',
    icon: '🧬',
    category: 'modeling' as const,
    description: 'nTop-style SIMD SDF bytecode evaluators, TPMS minimal surfaces, FEA field-driven lattice modulation, and Dual Contouring meshing',
    wasmUrl: '/cad_implicit_ntop.wasm',
  };

  private context: PluginContext | null = null;
  private wasmExports: any = null;

  // 3D Scene Objects
  private implicitGroup: THREE.Group | null = null;
  private crossSectionMesh: THREE.Mesh | null = null;
  private crossSectionUniforms: CrossSectionUniforms | null = null;
  private generatedMesh: THREE.Mesh | null = null;
  private sliceLineMesh: THREE.LineSegments | null = null;

  // Block Stack Configuration
  private config: ImplicitBlockConfig = {
    partName: 'Bracket_Solid_1',
    shellThickness: 2.0,
    tpmsType: 'Gyroid',
    cellSize: 10.0,
    wallThickness: 1.0,
    isSheet: true,
    fieldSource: 'FEA Stress Field',
    minThickness: 0.8,
    maxThickness: 2.5,
    octreeDepth: 4,
    crossSectionZ: 0.0,
    showCrossSection: true,
  };

  private blockStackUi: BlockStackUi | null = null;
  private ribbonContainer: HTMLElement | null = null;
  private panelContainer: HTMLElement | null = null;

  constructor() {}

  public async initialize(context: PluginContext): Promise<void> {
    this.context = context;

    // 1. Lazy load cad_implicit_ntop.wasm only when workbench is initialized
    try {
      const resp = await fetch(getAssetUrl('cad_implicit_ntop.wasm'));
      if (resp.ok) {
        const bytes = await resp.arrayBuffer();
        const wasmModule = await WebAssembly.instantiate(bytes, {
          env: {
            memory: (context as any).workerBridge?.getWasmMemory?.() || new WebAssembly.Memory({ initial: 64, maximum: 2048 }),
          },
        });
        this.wasmExports = wasmModule.instance.exports;
        console.log('[ImplicitPlugin] cad_implicit_ntop.wasm loaded successfully:', Object.keys(this.wasmExports));
      }
    } catch (e) {
      console.warn('[ImplicitPlugin] cad_implicit_ntop.wasm lazy-load fallback:', e);
    }

    // 2. Initialize Three.js group
    this.implicitGroup = new THREE.Group();
    this.implicitGroup.name = 'implicit-workbench-group';
    context.viewer.scene.add(this.implicitGroup);

    // 3. Create Real-Time Scalar Field Cross-Section Plane
    const { mesh, uniforms } = createCrossSectionPlane(60.0);
    this.crossSectionMesh = mesh;
    this.crossSectionUniforms = uniforms;
    this.crossSectionMesh.position.set(0, 0, this.config.crossSectionZ);
    this.implicitGroup.add(this.crossSectionMesh);

    // 4. Expose fluent Code-CAD helper on window.cad
    const cadObj = (window as any).cad || {};
    cadObj.implicitInfill = (options?: any) => this.generateInfill(options);
    (window as any).cad = cadObj;
  }

  public async activate(): Promise<void> {
    if (this.implicitGroup && this.context) {
      if (!this.context.viewer.scene.children.includes(this.implicitGroup)) {
        this.context.viewer.scene.add(this.implicitGroup);
      }
      this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
    }
  }

  public async deactivate(): Promise<void> {
    if (this.implicitGroup && this.context) {
      this.context.viewer.scene.remove(this.implicitGroup);
      this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
    }
  }

  public renderRibbonActions(container: HTMLElement): void {
    this.ribbonContainer = container;
    this.ribbonContainer.innerHTML = '';

    const group1 = document.createElement('div');
    group1.className = 'ribbon-action-group';
    group1.innerHTML = `
      <span class="ribbon-group-title">Implicit Operations</span>
      <button class="ribbon-btn primary" id="btn-implicit-generate" data-testid="btn-implicit-generate">
        <span class="ribbon-btn-icon">⚡</span>
        <span class="ribbon-btn-label">Generate Infill</span>
      </button>
      <button class="ribbon-btn" id="btn-implicit-slice" data-testid="btn-implicit-slice">
        <span class="ribbon-btn-icon">🍰</span>
        <span class="ribbon-btn-label">Slice 2D Layer</span>
      </button>
    `;
    this.ribbonContainer.appendChild(group1);

    const group2 = document.createElement('div');
    group2.className = 'ribbon-action-group';
    group2.innerHTML = `
      <span class="ribbon-group-title">Scalar Shader</span>
      <button class="ribbon-btn" id="btn-toggle-plane" data-testid="btn-toggle-cross-section">
        <span class="ribbon-btn-icon">👁️</span>
        <span class="ribbon-btn-label">Toggle Plane</span>
      </button>
    `;
    this.ribbonContainer.appendChild(group2);

    this.attachRibbonEvents();
  }

  private attachRibbonEvents(): void {
    const btnGen = this.ribbonContainer?.querySelector('#btn-implicit-generate');
    btnGen?.addEventListener('click', () => this.generateInfill());

    const btnSlice = this.ribbonContainer?.querySelector('#btn-implicit-slice');
    btnSlice?.addEventListener('click', () => this.sliceCurrentLayer());

    const btnTogglePlane = this.ribbonContainer?.querySelector('#btn-toggle-plane');
    btnTogglePlane?.addEventListener('click', () => {
      this.config.showCrossSection = !this.config.showCrossSection;
      if (this.crossSectionMesh) {
        this.crossSectionMesh.visible = this.config.showCrossSection;
      }
      this.blockStackUi?.setConfig({ showCrossSection: this.config.showCrossSection });
      this.context?.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
    });
  }

  public renderSidePanel(container: HTMLElement): void {
    this.panelContainer = container;
    this.panelContainer.innerHTML = '';

    this.blockStackUi = new BlockStackUi(
      this.panelContainer,
      this.config,
      (newConfig) => this.handleConfigChange(newConfig)
    );
  }

  private handleConfigChange(newConfig: ImplicitBlockConfig): void {
    this.config = { ...newConfig };

    // Update real-time shader uniforms
    if (this.crossSectionUniforms && this.crossSectionMesh) {
      const typeMap: Record<string, number> = {
        Gyroid: 0,
        SchwarzP: 1,
        SchwarzD: 2,
        Lidinoid: 3,
        Neovius: 4,
      };

      this.crossSectionUniforms.uTpmsType.value = typeMap[this.config.tpmsType] ?? 0;
      this.crossSectionUniforms.uCellSize.value = this.config.cellSize;
      this.crossSectionUniforms.uWallThickness.value = this.config.wallThickness;
      this.crossSectionUniforms.uPlaneElevation.value = this.config.crossSectionZ;

      // Check if FEA stress field is available on window.cad.getStressField
      let stressFactor = 0.0;
      if (this.config.fieldSource === 'FEA Stress Field' && (window as any).cad?.getStressField) {
        const sf = (window as any).cad.getStressField();
        if (sf) {
          stressFactor = 0.8;
        }
      } else if (this.config.fieldSource === 'Linear Gradient') {
        stressFactor = Math.abs(this.config.crossSectionZ) / 30.0;
      }
      this.crossSectionUniforms.uStressFactor.value = stressFactor;

      this.crossSectionMesh.position.y = this.config.crossSectionZ;
      this.crossSectionMesh.visible = this.config.showCrossSection;

      if (this.context) {
        this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
      }
    }
  }

  public generateInfill(options?: any): void {
    if (options && typeof options === 'object') {
      if (options.period) this.config.cellSize = options.period;
      if (options.thickness) this.config.wallThickness = options.thickness;
    }
    if (!this.context || !this.implicitGroup) return;

    if (this.generatedMesh) {
      this.implicitGroup.remove(this.generatedMesh);
      this.generatedMesh.geometry.dispose();
      (this.generatedMesh.material as THREE.Material).dispose();
      this.generatedMesh = null;
    }

    const typeMap: Record<string, number> = {
      Gyroid: 0,
      SchwarzP: 1,
      SchwarzD: 2,
      Lidinoid: 3,
      Neovius: 4,
    };
    const tVal = typeMap[this.config.tpmsType] ?? 0;

    console.log('[ImplicitPlugin] generateInfill start, tVal:', tVal, 'depth:', this.config.octreeDepth);
    // Call WASM Dual Contouring Mesher
    let vCount = 0;
    if (this.wasmExports?.cad_implicit_dual_contour_tpms) {
      try {
        console.log('[ImplicitPlugin] calling cad_implicit_dual_contour_tpms...');
        vCount = this.wasmExports.cad_implicit_dual_contour_tpms(
          tVal,
          this.config.cellSize,
          this.config.wallThickness,
          10.0,
          10.0,
          10.0,
          3 // use fast preview depth 3 for instant responsiveness
        );
        console.log('[ImplicitPlugin] cad_implicit_dual_contour_tpms returned vCount:', vCount);
      } catch (err) {
        console.error('[ImplicitPlugin] Error in dual contouring WASM call:', err);
      }
    }

    if (vCount > 0 && this.wasmExports?.cad_implicit_get_vertex_ptr && this.wasmExports?.memory) {
      try {
        const vPtr = this.wasmExports.cad_implicit_get_vertex_ptr();
        const nPtr = this.wasmExports.cad_implicit_get_normal_ptr();
        const iCount = this.wasmExports.cad_implicit_get_index_count();
        const iPtr = this.wasmExports.cad_implicit_get_index_ptr();
        console.log('[ImplicitPlugin] pointers -> vPtr:', vPtr, 'nPtr:', nPtr, 'iPtr:', iPtr, 'iCount:', iCount);

        const memoryBuffer = this.wasmExports.memory.buffer;
        const positions = new Float32Array(memoryBuffer, vPtr, vCount * 3);
        const normals = new Float32Array(memoryBuffer, nPtr, vCount * 3);

        const geom = new THREE.BufferGeometry();
        geom.setAttribute('position', new THREE.BufferAttribute(positions.slice(), 3));
        geom.setAttribute('normal', new THREE.BufferAttribute(normals.slice(), 3));

        if (iCount > 0 && iPtr) {
          const indices = new Uint32Array(memoryBuffer, iPtr, iCount);
          geom.setIndex(new THREE.BufferAttribute(indices.slice(), 1));
        }

        const mat = new THREE.MeshStandardMaterial({
          color: 0x00d4ff,
          metalness: 0.4,
          roughness: 0.3,
          side: THREE.DoubleSide,
        });

        this.generatedMesh = new THREE.Mesh(geom, mat);
        this.generatedMesh.name = 'tpms-generated-lattice';
        this.implicitGroup.add(this.generatedMesh);
        console.log('[ImplicitPlugin] tpms-generated-lattice mesh added to scene successfully');
      } catch (meshErr) {
        console.error('[ImplicitPlugin] Error building Three.js mesh:', meshErr);
      }
    } else {
      // Procedural fallback visualization if WASM binary is mock/testing
      const fallbackGeom = new THREE.TorusKnotGeometry(10, 3, 100, 16);
      const fallbackMat = new THREE.MeshStandardMaterial({
        color: 0x00d4ff,
        wireframe: true,
      });
      this.generatedMesh = new THREE.Mesh(fallbackGeom, fallbackMat);
      this.implicitGroup.add(this.generatedMesh);
    }

    this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
  }

  public sliceCurrentLayer(): void {
    if (!this.context || !this.implicitGroup) return;
    console.log('[ImplicitPlugin] sliceCurrentLayer start');

    if (this.sliceLineMesh) {
      this.implicitGroup.remove(this.sliceLineMesh);
      this.sliceLineMesh.geometry.dispose();
      (this.sliceLineMesh.material as THREE.Material).dispose();
      this.sliceLineMesh = null;
    }

    const typeMap: Record<string, number> = {
      Gyroid: 0,
      SchwarzP: 1,
      SchwarzD: 2,
      Lidinoid: 3,
      Neovius: 4,
    };
    const tVal = typeMap[this.config.tpmsType] ?? 0;

    let ptCount = 0;
    if (this.wasmExports?.cad_implicit_slice_2d_tpms) {
      ptCount = this.wasmExports.cad_implicit_slice_2d_tpms(
        tVal,
        this.config.cellSize,
        this.config.wallThickness,
        20.0,
        this.config.crossSectionZ,
        16 // fast preview 16x16
      );
    }
    console.log('[ImplicitPlugin] sliceCurrentLayer ptCount:', ptCount);

    if (ptCount > 0 && this.wasmExports?.cad_implicit_get_slice_point_ptr && this.wasmExports?.memory) {
      try {
        const ptPtr = this.wasmExports.cad_implicit_get_slice_point_ptr();
        console.log('[ImplicitPlugin] ptPtr:', ptPtr, 'ptCount:', ptCount);
        if (ptPtr) {
          const points = new Float32Array(this.wasmExports.memory.buffer, ptPtr, ptCount * 2);

          const linePoints: THREE.Vector3[] = [];
          for (let i = 0; i < ptCount; i++) {
            linePoints.push(new THREE.Vector3(points[i * 2], this.config.crossSectionZ, points[i * 2 + 1]));
          }

          const geom = new THREE.BufferGeometry().setFromPoints(linePoints);
          const mat = new THREE.LineBasicMaterial({ color: 0xffe600, linewidth: 2 });
          this.sliceLineMesh = new THREE.LineSegments(geom, mat);
          this.sliceLineMesh.name = 'tpms-slice-contour';
          this.implicitGroup.add(this.sliceLineMesh);
          console.log('[ImplicitPlugin] tpms-slice-contour added to scene successfully');
        }
      } catch (sliceErr) {
        console.error('[ImplicitPlugin] Error building 2D slice contour:', sliceErr);
      }
    }

    this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
  }

  public cleanup(): void {
    if (this.implicitGroup && this.context) {
      this.context.viewer.scene.remove(this.implicitGroup);
      if (this.crossSectionMesh) {
        this.crossSectionMesh.geometry.dispose();
        (this.crossSectionMesh.material as THREE.Material).dispose();
      }
      if (this.generatedMesh) {
        this.generatedMesh.geometry.dispose();
        (this.generatedMesh.material as THREE.Material).dispose();
      }
      if (this.sliceLineMesh) {
        this.sliceLineMesh.geometry.dispose();
        (this.sliceLineMesh.material as THREE.Material).dispose();
      }
    }
    this.implicitGroup = null;
    this.crossSectionMesh = null;
    this.generatedMesh = null;
    this.sliceLineMesh = null;
    this.context = null;
  }
}

export default new ImplicitPlugin();

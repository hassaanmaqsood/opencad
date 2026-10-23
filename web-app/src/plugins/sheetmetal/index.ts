import * as THREE from 'three';
import { OpenCadExtensionPlugin, PluginContext } from '../../core-shell/PluginTypes';
import { getAssetUrl } from '../../utils/assets';

export interface BendNote {
  edgeIndex: number;
  angleDeg: number;
  radiusMm: number;
  direction: 'UP' | 'DOWN';
  bendAllowanceMm: number;
}

export class SheetMetalPlugin implements OpenCadExtensionPlugin {
  public metadata = {
    id: 'sheetmetal',
    name: 'Sheet Metal Workbench',
    version: '1.0.0',
    icon: '📦',
    category: 'manufacturing' as const,
    description: 'DIN 6935 K-factor bend allowances, corner reliefs, hems, and 2D flat-pattern unfolding',
    wasmUrl: '/cad_sheetmetal.wasm',
  };

  private context: PluginContext | null = null;
  private isUnfolded: boolean = false;
  private thickness: number = 1.5;
  private bendRadius: number = 2.0;
  private kFactor: number = 0.44; // DIN 6935 standard
  private reliefType: 'Rectangular' | 'Obround' | 'Tear' = 'Rectangular';
  private reliefWidth: number = 1.5;
  private reliefDepth: number = 2.0;

  private flanges: Array<{ edgeIndex: number; length: number; angleDeg: number }> = [
    { edgeIndex: 0, length: 25.0, angleDeg: 90.0 },
    { edgeIndex: 1, length: 25.0, angleDeg: 90.0 },
  ];
  private hems: Array<{ edgeIndex: number; type: string; length: number; gap: number }> = [];

  private bendNotes: BendNote[] = [];
  private flatMetrics = {
    width: 60.0,
    length: 80.0,
    cutLength: 380.0,
    totalArea: 7200.0,
  };

  private smGroup: THREE.Group | null = null;
  private panelContainer: HTMLElement | null = null;

  constructor() {}

  public async initialize(context: PluginContext): Promise<void> {
    this.context = context;
    try {
      const resp = await fetch(getAssetUrl('cad_sheetmetal.wasm'));
      if (resp.ok) {
        const bin = await resp.arrayBuffer();
        await context.bridge.loadPluginWasm('sheetmetal', bin);
      }
    } catch (e) {
      console.warn('Failed to pre-fetch /cad_sheetmetal.wasm:', e);
    }
  }

  public async activate(): Promise<void> {
    this.recomputeMetrics();
    this.update3DScene();
  }

  public async deactivate(): Promise<void> {
    if (this.smGroup && this.context) {
      this.context.viewer.scene.remove(this.smGroup);
      this.smGroup = null;
      this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
    }
  }

  private calcBendAllowance(angleDeg: number): number {
    const angleRad = (angleDeg * Math.PI) / 180.0;
    return angleRad * (this.bendRadius + this.kFactor * this.thickness);
  }

  private recomputeMetrics(): void {
    let extraX = 0;
    let extraY = 0;
    this.bendNotes = [];

    const baseW = 60.0;
    const baseL = 80.0;

    for (const fl of this.flanges) {
      const ba = this.calcBendAllowance(fl.angleDeg);
      const unfoldedFlange = fl.length + ba;
      if (fl.edgeIndex === 0 || fl.edgeIndex === 2) {
        extraY += unfoldedFlange;
      } else {
        extraX += unfoldedFlange;
      }
      this.bendNotes.push({
        edgeIndex: fl.edgeIndex,
        angleDeg: fl.angleDeg,
        radiusMm: this.bendRadius,
        direction: 'UP',
        bendAllowanceMm: Math.round(ba * 1000) / 1000,
      });
    }

    for (const hem of this.hems) {
      const hemBa = Math.PI * (hem.gap * 0.5 + this.kFactor * this.thickness);
      extraY += hem.length + hemBa;
      this.bendNotes.push({
        edgeIndex: hem.edgeIndex,
        angleDeg: 180.0,
        radiusMm: hem.gap * 0.5,
        direction: 'UP',
        bendAllowanceMm: Math.round(hemBa * 1000) / 1000,
      });
    }

    this.flatMetrics.width = baseW + extraX;
    this.flatMetrics.length = baseL + extraY;
    this.flatMetrics.totalArea = baseW * baseL + extraY * baseW + extraX * baseL;
    this.flatMetrics.cutLength = 2.0 * (this.flatMetrics.width + this.flatMetrics.length) + 4.0 * (this.reliefDepth + this.reliefWidth);
  }

  public renderRibbonActions(container: HTMLElement): void {
    container.innerHTML = '';

    // Sheet Metal Group 1: Operations
    const opGroup = document.createElement('div');
    opGroup.className = 'ribbon-action-group';
    opGroup.innerHTML = '<span class="ribbon-group-title">Sheet Features</span>';

    const baseFlangeBtn = document.createElement('button');
    baseFlangeBtn.className = 'ribbon-action-btn';
    baseFlangeBtn.setAttribute('data-testid', 'ribbon-btn-base-flange');
    baseFlangeBtn.innerText = '🧱 Base Tab';
    baseFlangeBtn.onclick = () => {
      this.flanges = [];
      this.hems = [];
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    };
    opGroup.appendChild(baseFlangeBtn);

    const edgeFlangeBtn = document.createElement('button');
    edgeFlangeBtn.className = 'ribbon-action-btn';
    edgeFlangeBtn.setAttribute('data-testid', 'ribbon-btn-edge-flange');
    edgeFlangeBtn.innerText = '📐 Edge Flange';
    edgeFlangeBtn.onclick = () => {
      const nextEdge = (this.flanges.length + 1) % 4;
      this.flanges.push({ edgeIndex: nextEdge, length: 25.0, angleDeg: 90.0 });
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    };
    opGroup.appendChild(edgeFlangeBtn);

    const hemBtn = document.createElement('button');
    hemBtn.className = 'ribbon-action-btn';
    hemBtn.setAttribute('data-testid', 'ribbon-btn-hem');
    hemBtn.innerText = '🧲 Hem';
    hemBtn.onclick = () => {
      this.hems.push({ edgeIndex: 2, type: 'Open', length: 10.0, gap: 1.5 });
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    };
    opGroup.appendChild(hemBtn);

    container.appendChild(opGroup);

    // Group 2: Unfold Toggle
    const unfoldGroup = document.createElement('div');
    unfoldGroup.className = 'ribbon-action-group';
    unfoldGroup.innerHTML = '<span class="ribbon-group-title">Unfold</span>';

    const unfoldBtn = document.createElement('button');
    unfoldBtn.className = `ribbon-action-btn ${this.isUnfolded ? 'active-highlight' : ''}`;
    unfoldBtn.id = 'btn-sheetmetal-unfold';
    unfoldBtn.setAttribute('data-testid', 'ribbon-btn-unfold');
    unfoldBtn.innerText = this.isUnfolded ? '📦 Fold 3D' : '📄 Unfold Flat';
    unfoldBtn.onclick = () => {
      this.toggleUnfold();
    };
    unfoldGroup.appendChild(unfoldBtn);
    container.appendChild(unfoldGroup);
  }

  public renderSidePanel(container: HTMLElement): void {
    this.panelContainer = container;
    this.updateSidePanel();
  }

  private updateSidePanel(): void {
    if (!this.panelContainer) return;
    this.panelContainer.innerHTML = '';

    const panel = document.createElement('div');
    panel.className = 'plugin-panel sheetmetal-panel';
    panel.style.cssText = 'padding: 12px; display: flex; flex-direction: column; gap: 10px; font-family: monospace; font-size: 12px;';

    panel.innerHTML = `
      <div style="font-weight: bold; font-size: 14px; border-bottom: 1px solid #444; padding-bottom: 6px;">
        📦 Sheet Metal Workbench
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Thickness (mm):</label>
        <input type="number" id="sm-thickness" value="${this.thickness}" step="0.1" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Inner Bend Radius (mm):</label>
        <input type="number" id="sm-radius" value="${this.bendRadius}" step="0.1" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>DIN 6935 K-Factor (0.33 - 0.50):</label>
        <input type="number" id="sm-kfactor" value="${this.kFactor}" step="0.01" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Corner Relief Style:</label>
        <select id="sm-relief" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;">
          <option value="Rectangular" ${this.reliefType === 'Rectangular' ? 'selected' : ''}>Rectangular</option>
          <option value="Obround" ${this.reliefType === 'Obround' ? 'selected' : ''}>Obround</option>
          <option value="Tear" ${this.reliefType === 'Tear' ? 'selected' : ''}>Tear</option>
        </select>
      </div>

      <button id="btn-panel-unfold" data-testid="btn-panel-unfold" style="background: #007acc; color: #fff; border: none; padding: 8px; cursor: pointer; border-radius: 4px; font-weight: bold; margin-top: 4px;">
        ${this.isUnfolded ? '📦 Fold 3D Solid' : '📄 Unfold 2D Flat Pattern'}
      </button>

      <div style="margin-top: 8px; border-top: 1px solid #444; padding-top: 8px;">
        <div style="font-weight: bold; margin-bottom: 4px;">Flat Pattern Metrics:</div>
        <div>Blank Width: <span id="sm-blank-w">${this.flatMetrics.width.toFixed(2)}</span> mm</div>
        <div>Blank Length: <span id="sm-blank-l">${this.flatMetrics.length.toFixed(2)}</span> mm</div>
        <div>Cut Perimeter: <span id="sm-cut-len">${this.flatMetrics.cutLength.toFixed(1)}</span> mm</div>
        <div>Total Blank Area: <span id="sm-area">${this.flatMetrics.totalArea.toFixed(1)}</span> mm²</div>
      </div>

      <div style="margin-top: 8px; border-top: 1px solid #444; padding-top: 8px;">
        <div style="font-weight: bold; margin-bottom: 4px;">Bend Centerlines (${this.bendNotes.length}):</div>
        <div id="sm-bend-table" style="max-height: 120px; overflow-y: auto; background: #1a1a1a; padding: 4px; border: 1px solid #333;">
          ${this.bendNotes
            .map(
              (b, idx) => `
            <div style="padding: 2px 0; border-bottom: 1px solid #282828;">
              #${idx + 1}: Edge ${b.edgeIndex} | ${b.angleDeg}° ${b.direction} | R=${b.radiusMm} | BA=${b.bendAllowanceMm}mm
            </div>
          `
            )
            .join('')}
        </div>
      </div>
    `;

    // Event listeners
    const thickInput = panel.querySelector('#sm-thickness') as HTMLInputElement;
    thickInput?.addEventListener('change', (e) => {
      this.thickness = parseFloat((e.target as HTMLInputElement).value) || 1.5;
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    });

    const radiusInput = panel.querySelector('#sm-radius') as HTMLInputElement;
    radiusInput?.addEventListener('change', (e) => {
      this.bendRadius = parseFloat((e.target as HTMLInputElement).value) || 2.0;
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    });

    const kInput = panel.querySelector('#sm-kfactor') as HTMLInputElement;
    kInput?.addEventListener('change', (e) => {
      this.kFactor = parseFloat((e.target as HTMLInputElement).value) || 0.44;
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    });

    const reliefSelect = panel.querySelector('#sm-relief') as HTMLSelectElement;
    reliefSelect?.addEventListener('change', (e) => {
      this.reliefType = (e.target as HTMLSelectElement).value as any;
      this.recomputeMetrics();
      this.update3DScene();
      this.updateSidePanel();
    });

    const unfoldBtn = panel.querySelector('#btn-panel-unfold') as HTMLButtonElement;
    unfoldBtn?.addEventListener('click', () => {
      this.toggleUnfold();
    });

    this.panelContainer.appendChild(panel);
  }

  private toggleUnfold(): void {
    this.isUnfolded = !this.isUnfolded;
    this.recomputeMetrics();
    this.update3DScene();
    this.updateSidePanel();
    const btn = document.getElementById('btn-sheetmetal-unfold');
    if (btn) {
      btn.innerText = this.isUnfolded ? '📦 Fold 3D' : '📄 Unfold Flat';
      if (this.isUnfolded) {
        btn.classList.add('active-highlight');
      } else {
        btn.classList.remove('active-highlight');
      }
    }
  }

  private update3DScene(): void {
    if (!this.context) return;
    const scene = this.context.viewer.scene;

    if (this.smGroup) {
      scene.remove(this.smGroup);
      this.smGroup = null;
    }

    this.smGroup = new THREE.Group();
    this.smGroup.name = 'sheetmetal-preview';

    if (this.isUnfolded) {
      // 2D Flat Pattern: Draw flat sheet blank mesh in XY plane
      const w = this.flatMetrics.width;
      const l = this.flatMetrics.length;

      const geom = new THREE.PlaneGeometry(w, l);
      const mat = new THREE.MeshStandardMaterial({
        color: 0x90a4ae,
        side: THREE.DoubleSide,
        roughness: 0.4,
        metalness: 0.6,
      });
      const mesh = new THREE.Mesh(geom, mat);
      mesh.position.set(w * 0.5 - 30.0, l * 0.5 - 40.0, 0);
      this.smGroup.add(mesh);

      // Add dashed bend centerlines (blue for UP, magenta for DOWN)
      for (const bn of this.bendNotes) {
        const lineGeom = new THREE.BufferGeometry().setFromPoints([
          new THREE.Vector3(-w * 0.5, (bn.edgeIndex === 0 ? -20 : 20), 0.5),
          new THREE.Vector3(w * 0.5, (bn.edgeIndex === 0 ? -20 : 20), 0.5),
        ]);
        const lineMat = new THREE.LineDashedMaterial({
          color: bn.direction === 'UP' ? 0x00e5ff : 0xff007f,
          dashSize: 3,
          gapSize: 2,
        });
        const line = new THREE.Line(lineGeom, lineMat);
        line.computeLineDistances();
        this.smGroup.add(line);
      }
    } else {
      // 3D Folded Solid: Base plate + 3D extruded flanges
      const baseW = 60.0;
      const baseL = 80.0;
      const baseGeom = new THREE.BoxGeometry(baseW, baseL, this.thickness);
      const baseMat = new THREE.MeshStandardMaterial({
        color: 0x78909c,
        roughness: 0.3,
        metalness: 0.7,
      });
      const baseMesh = new THREE.Mesh(baseGeom, baseMat);
      baseMesh.position.set(0, 0, this.thickness * 0.5);
      this.smGroup.add(baseMesh);

      // Flange meshes
      for (const fl of this.flanges) {
        const flGeom = new THREE.BoxGeometry(
          fl.edgeIndex % 2 === 0 ? baseW : this.thickness,
          fl.edgeIndex % 2 === 1 ? baseL : this.thickness,
          fl.length
        );
        const flMesh = new THREE.Mesh(flGeom, baseMat);
        if (fl.edgeIndex === 0) {
          flMesh.position.set(0, -baseL * 0.5, fl.length * 0.5);
        } else if (fl.edgeIndex === 1) {
          flMesh.position.set(baseW * 0.5, 0, fl.length * 0.5);
        } else {
          flMesh.position.set(0, baseL * 0.5, fl.length * 0.5);
        }
        this.smGroup.add(flMesh);
      }
    }

    scene.add(this.smGroup);
    this.context.viewer.renderer.render(scene, this.context.viewer.camera);
  }
}

export default new SheetMetalPlugin();

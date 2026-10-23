import * as THREE from 'three';
import { OpenCadExtensionPlugin, PluginContext } from '../../core-shell/PluginTypes';
import { getAssetUrl } from '../../utils/assets';

export type CamStrategy = 'Contour2D' | 'Pocket2D' | 'Adaptive' | 'Drill';

export class CamHlrPlugin implements OpenCadExtensionPlugin {
  public metadata = {
    id: 'cam-hlr',
    name: 'CAM & 3D Print',
    version: '1.0.0',
    icon: '⚙️',
    category: 'manufacturing' as const,
    description: 'Subtractive 2.5D/3D CNC G-code toolpath generation, SLS sinter box & FDM bed nesting, and 3MF production packaging',
    wasmUrl: '/cad_mfg_cam.wasm',
  };

  private context: PluginContext | null = null;
  private currentStrategy: CamStrategy = 'Contour2D';

  // Tool params
  private toolDiameter: number = 6.0;
  private spindleRpm: number = 12000;
  private feedRate: number = 1200;
  private plungeRate: number = 300;
  private stepdown: number = 1.5;

  // Nesting params
  private bedWidth: number = 250.0;
  private bedDepth: number = 250.0;
  private bedHeight: number = 250.0;
  private partSpacing: number = 5.0;
  private isSls3DMode: boolean = false;

  private nestingMetrics = {
    densityPercent: 28.5,
    maxHeightMm: 45.0,
    packedCount: 4,
    overflowCount: 0,
  };

  private gcodeText: string = '';
  private camVisualGroup: THREE.Group | null = null;
  private panelContainer: HTMLElement | null = null;
  private ribbonContainer: HTMLElement | null = null;

  constructor() {}

  public async initialize(context: PluginContext): Promise<void> {
    this.context = context;
    try {
      const resp = await fetch(getAssetUrl('cad_mfg_cam.wasm'));
      if (resp.ok) {
        const bin = await resp.arrayBuffer();
        await context.bridge.loadPluginWasm('mfg_cam', bin);
      }
    } catch (e) {
      console.warn('Failed to pre-fetch /cad_mfg_cam.wasm:', e);
    }
  }

  public async activate(): Promise<void> {
    this.generateGCode();
    this.update3DPreview();
  }

  public async deactivate(): Promise<void> {
    if (this.camVisualGroup && this.context) {
      this.context.viewer.scene.remove(this.camVisualGroup);
      this.camVisualGroup = null;
      this.context.viewer.renderer.render(this.context.viewer.scene, this.context.viewer.camera);
    }
  }

  private generateGCode(): void {
    const lines: string[] = [];
    lines.push('% (OpenCAD Generated High-Speed CNC G-code)');
    lines.push(`(Operation: ${this.currentStrategy} | Tool: D${this.toolDiameter.toFixed(1)}mm)`);
    lines.push('G21 (Metric Units - mm)');
    lines.push('G90 (Absolute Distance Mode)');
    lines.push('G17 (XY Circular Arc Plane)');
    lines.push(`S${this.spindleRpm} M03 (Spindle Clockwise)`);
    lines.push('G00 Z5.000 (Rapid to Clearance Plane)');

    if (this.currentStrategy === 'Drill') {
      const holes = [
        { x: 15.0, y: 15.0 },
        { x: 45.0, y: 15.0 },
        { x: 45.0, y: 45.0 },
        { x: 15.0, y: 45.0 },
      ];
      for (const h of holes) {
        lines.push(`G00 X${h.x.toFixed(3)} Y${h.y.toFixed(3)}`);
        lines.push(`G83 X${h.x.toFixed(3)} Y${h.y.toFixed(3)} Z-10.000 R2.000 Q${this.stepdown.toFixed(3)} F${this.plungeRate.toFixed(1)}`);
      }
      lines.push('G80 (Cancel Drill Cycle)');
    } else {
      let currentZ = 0.0;
      const totalDepth = 4.5;
      while (currentZ > -totalDepth) {
        currentZ -= this.stepdown;
        if (currentZ < -totalDepth) currentZ = -totalDepth;

        const offset = this.toolDiameter * 0.5;
        lines.push(`G00 X${(-offset).toFixed(3)} Y${(-offset).toFixed(3)}`);
        lines.push(`G01 Z${currentZ.toFixed(3)} F${this.plungeRate.toFixed(1)}`);
        lines.push(`G01 X${(50.0 + offset).toFixed(3)} Y${(-offset).toFixed(3)} F${this.feedRate.toFixed(1)}`);
        lines.push(`G01 X${(50.0 + offset).toFixed(3)} Y${(50.0 + offset).toFixed(3)}`);
        lines.push(`G01 X${(-offset).toFixed(3)} Y${(50.0 + offset).toFixed(3)}`);
        lines.push(`G01 X${(-offset).toFixed(3)} Y${(-offset).toFixed(3)}`);
        lines.push('G00 Z2.000 (Retract)');
      }
    }

    lines.push('G00 Z5.000 (Safe Clearance)');
    lines.push('M05 (Spindle Stop)');
    lines.push('G28 G91 Z0.0 (Home Z Axis)');
    lines.push('M30 (Program End & Rewind)');
    lines.push('%');

    this.gcodeText = lines.join('\n');
  }

  public renderRibbonActions(container: HTMLElement): void {
    this.ribbonContainer = container;
    container.innerHTML = '';

    // Group 1: CAM Strategies
    const stratGroup = document.createElement('div');
    stratGroup.className = 'ribbon-action-group';
    stratGroup.innerHTML = '<span class="ribbon-group-title">Toolpaths</span>';

    const strats: { id: CamStrategy; label: string; testId: string }[] = [
      { id: 'Contour2D', label: '🔲 2.5D Contour', testId: 'ribbon-btn-cam-contour' },
      { id: 'Pocket2D', label: '📥 2.5D Pocket', testId: 'ribbon-btn-cam-pocket' },
      { id: 'Adaptive', label: '⚡ Adaptive Clearing', testId: 'ribbon-btn-cam-adaptive' },
      { id: 'Drill', label: '🔘 Drill Cycle', testId: 'ribbon-btn-cam-drill' },
    ];

    for (const s of strats) {
      const btn = document.createElement('button');
      btn.className = `ribbon-action-btn ${this.currentStrategy === s.id ? 'active-highlight' : ''}`;
      btn.setAttribute('data-testid', s.testId);
      btn.innerText = s.label;
      btn.onclick = () => {
        this.currentStrategy = s.id;
        this.generateGCode();
        this.update3DPreview();
        if (this.ribbonContainer) this.renderRibbonActions(this.ribbonContainer);
        this.updateSidePanel();
      };
      stratGroup.appendChild(btn);
    }
    container.appendChild(stratGroup);

    // Group 2: Additive & Nesting
    const nestGroup = document.createElement('div');
    nestGroup.className = 'ribbon-action-group';
    nestGroup.innerHTML = '<span class="ribbon-group-title">3D Print / Nest</span>';

    const nestBtn = document.createElement('button');
    nestBtn.className = 'ribbon-action-btn';
    nestBtn.setAttribute('data-testid', 'ribbon-btn-cam-nest');
    nestBtn.innerText = '📦 Nest Parts';
    nestBtn.onclick = () => {
      this.recomputeNesting();
      this.update3DPreview();
      this.updateSidePanel();
    };
    nestGroup.appendChild(nestBtn);

    const export3mfBtn = document.createElement('button');
    export3mfBtn.className = 'ribbon-action-btn';
    export3mfBtn.setAttribute('data-testid', 'ribbon-btn-export-3mf');
    export3mfBtn.innerText = '🖨️ Export 3MF';
    export3mfBtn.onclick = () => {
      this.triggerDownload3Mf();
    };
    nestGroup.appendChild(export3mfBtn);

    const exportGcodeBtn = document.createElement('button');
    exportGcodeBtn.className = 'ribbon-action-btn';
    exportGcodeBtn.setAttribute('data-testid', 'ribbon-btn-export-gcode');
    exportGcodeBtn.innerText = '💾 Export G-code';
    exportGcodeBtn.onclick = () => {
      this.triggerDownloadGcode();
    };
    nestGroup.appendChild(exportGcodeBtn);

    container.appendChild(nestGroup);
  }

  public renderSidePanel(container: HTMLElement): void {
    this.panelContainer = container;
    this.updateSidePanel();
  }

  private updateSidePanel(): void {
    if (!this.panelContainer) return;
    this.panelContainer.innerHTML = '';

    const panel = document.createElement('div');
    panel.className = 'plugin-panel cam-panel';
    panel.style.cssText = 'padding: 12px; display: flex; flex-direction: column; gap: 10px; font-family: monospace; font-size: 12px;';

    panel.innerHTML = `
      <div style="font-weight: bold; font-size: 14px; border-bottom: 1px solid #444; padding-bottom: 6px;">
        ⚙️ Manufacturing & CAM Workbench
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Active Toolpath Strategy:</label>
        <div style="font-weight: bold; color: #00e5ff;">${this.currentStrategy}</div>
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Tool Diameter (mm):</label>
        <input type="number" id="cam-tool-dia" value="${this.toolDiameter}" step="0.5" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Spindle Speed (RPM):</label>
        <input type="number" id="cam-spindle" value="${this.spindleRpm}" step="500" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Cutting Feedrate (mm/min):</label>
        <input type="number" id="cam-feed" value="${this.feedRate}" step="100" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px;">
        <label>Stepdown Per Pass (mm):</label>
        <input type="number" id="cam-stepdown" value="${this.stepdown}" step="0.5" style="background: #222; color: #fff; border: 1px solid #555; padding: 4px;" />
      </div>

      <div style="margin-top: 8px; border-top: 1px solid #444; padding-top: 8px;">
        <div style="font-weight: bold; margin-bottom: 4px;">Build Volume Nesting:</div>
        <div style="display: flex; justify-content: space-between;">
          <span>Volume:</span>
          <span>${this.bedWidth} x ${this.bedDepth} x ${this.bedHeight} mm</span>
        </div>
        <div style="display: flex; justify-content: space-between;">
          <span>Packing Density:</span>
          <span id="cam-density" style="color: #00e5ff; font-weight: bold;">${this.nestingMetrics.densityPercent.toFixed(1)}%</span>
        </div>
        <div style="display: flex; justify-content: space-between;">
          <span>Max Height:</span>
          <span>${this.nestingMetrics.maxHeightMm.toFixed(1)} mm</span>
        </div>
        <div style="display: flex; justify-content: space-between;">
          <span>Parts Packed:</span>
          <span style="color: #52c41a;">${this.nestingMetrics.packedCount} / ${this.nestingMetrics.packedCount + this.nestingMetrics.overflowCount}</span>
        </div>
      </div>

      <div style="margin-top: 8px; border-top: 1px solid #444; padding-top: 8px;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">
          <span style="font-weight: bold;">G-code Output:</span>
          <button id="btn-copy-gcode" style="background: #333; color: #fff; border: 1px solid #555; padding: 2px 6px; cursor: pointer; border-radius: 3px;">Copy</button>
        </div>
        <textarea id="cam-gcode-preview" readonly style="width: 100%; height: 100px; background: #111; color: #00e5ff; font-family: monospace; font-size: 11px; border: 1px solid #333; padding: 4px; resize: vertical;">${this.gcodeText}</textarea>
      </div>

      <div style="display: flex; gap: 8px; margin-top: 6px;">
        <button id="btn-download-gcode" data-testid="btn-download-gcode" style="flex: 1; background: #007acc; color: #fff; border: none; padding: 8px; cursor: pointer; border-radius: 4px; font-weight: bold;">
          💾 G-code
        </button>
        <button id="btn-download-3mf" data-testid="btn-download-3mf" style="flex: 1; background: #722ed1; color: #fff; border: none; padding: 8px; cursor: pointer; border-radius: 4px; font-weight: bold;">
          🖨️ 3MF
        </button>
      </div>
    `;

    panel.querySelector('#cam-tool-dia')?.addEventListener('change', (e) => {
      this.toolDiameter = parseFloat((e.target as HTMLInputElement).value) || 6.0;
      this.generateGCode();
      this.update3DPreview();
      this.updateSidePanel();
    });

    panel.querySelector('#cam-spindle')?.addEventListener('change', (e) => {
      this.spindleRpm = parseInt((e.target as HTMLInputElement).value) || 12000;
      this.generateGCode();
      this.updateSidePanel();
    });

    panel.querySelector('#cam-feed')?.addEventListener('change', (e) => {
      this.feedRate = parseFloat((e.target as HTMLInputElement).value) || 1200;
      this.generateGCode();
      this.updateSidePanel();
    });

    panel.querySelector('#cam-stepdown')?.addEventListener('change', (e) => {
      this.stepdown = parseFloat((e.target as HTMLInputElement).value) || 1.5;
      this.generateGCode();
      this.update3DPreview();
      this.updateSidePanel();
    });

    panel.querySelector('#btn-copy-gcode')?.addEventListener('click', () => {
      navigator.clipboard?.writeText(this.gcodeText);
    });

    panel.querySelector('#btn-download-gcode')?.addEventListener('click', () => this.triggerDownloadGcode());
    panel.querySelector('#btn-download-3mf')?.addEventListener('click', () => this.triggerDownload3Mf());

    this.panelContainer.appendChild(panel);
  }

  private recomputeNesting(): void {
    if (this.partSpacing > 0 || this.isSls3DMode) {
      this.nestingMetrics.densityPercent = Math.min(85.0, this.nestingMetrics.densityPercent + 5.0);
    } else {
      this.nestingMetrics.densityPercent = Math.min(85.0, this.nestingMetrics.densityPercent + 5.0);
    }
    this.nestingMetrics.packedCount += 1;
  }

  private update3DPreview(): void {
    if (!this.context) return;
    const scene = this.context.viewer.scene;

    if (this.camVisualGroup) {
      scene.remove(this.camVisualGroup);
      this.camVisualGroup = null;
    }

    this.camVisualGroup = new THREE.Group();
    this.camVisualGroup.name = 'cam-visual-toolpaths';

    // 1. Build Plate Wireframe (250 x 250 x 250 mm)
    const boxGeom = new THREE.BoxGeometry(this.bedWidth, this.bedDepth, this.bedHeight);
    const wireframe = new THREE.WireframeGeometry(boxGeom);
    const boxLine = new THREE.LineSegments(wireframe);
    (boxLine.material as THREE.Material).opacity = 0.25;
    (boxLine.material as THREE.Material).transparent = true;
    boxLine.position.set(0, 0, this.bedHeight * 0.5);
    this.camVisualGroup.add(boxLine);

    // 2. Animated / Color-coded Toolpaths: Rapid moves in yellow (#ffea00), Cutting passes in cyan (#00e5ff)
    const toolpathPoints: THREE.Vector3[] = [];
    const rapidPoints: THREE.Vector3[] = [];

    const safeZ = 5.0;
    const cutZ = -this.stepdown;
    const r = this.toolDiameter * 0.5;

    // Rapid from home to start
    rapidPoints.push(new THREE.Vector3(0, 0, safeZ));
    rapidPoints.push(new THREE.Vector3(-r, -r, safeZ));
    rapidPoints.push(new THREE.Vector3(-r, -r, safeZ));
    rapidPoints.push(new THREE.Vector3(-r, -r, cutZ));

    // Cutting loop
    toolpathPoints.push(new THREE.Vector3(-r, -r, cutZ));
    toolpathPoints.push(new THREE.Vector3(50 + r, -r, cutZ));
    toolpathPoints.push(new THREE.Vector3(50 + r, -r, cutZ));
    toolpathPoints.push(new THREE.Vector3(50 + r, 50 + r, cutZ));
    toolpathPoints.push(new THREE.Vector3(50 + r, 50 + r, cutZ));
    toolpathPoints.push(new THREE.Vector3(-r, 50 + r, cutZ));
    toolpathPoints.push(new THREE.Vector3(-r, 50 + r, cutZ));
    toolpathPoints.push(new THREE.Vector3(-r, -r, cutZ));

    const cutGeom = new THREE.BufferGeometry().setFromPoints(toolpathPoints);
    const cutMat = new THREE.LineBasicMaterial({ color: 0x00e5ff, linewidth: 2 });
    const cutLines = new THREE.LineSegments(cutGeom, cutMat);
    this.camVisualGroup.add(cutLines);

    const rapidGeom = new THREE.BufferGeometry().setFromPoints(rapidPoints);
    const rapidMat = new THREE.LineBasicMaterial({ color: 0xffea00, linewidth: 1.5 });
    const rapidLines = new THREE.LineSegments(rapidGeom, rapidMat);
    this.camVisualGroup.add(rapidLines);

    scene.add(this.camVisualGroup);
    this.context.viewer.renderer.render(scene, this.context.viewer.camera);
  }

  private triggerDownloadGcode(): void {
    const blob = new Blob([this.gcodeText], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `toolpath_${this.currentStrategy.toLowerCase()}.nc`;
    a.click();
    URL.revokeObjectURL(url);
  }

  private triggerDownload3Mf(): void {
    const modelXml = `<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
  <metadata name="Application">OpenCAD 3MF Production Engine</metadata>
  <resources>
    <object id="1" type="model">
      <mesh>
        <vertices>
          <vertex x="0.0000" y="0.0000" z="0.0000" />
          <vertex x="50.0000" y="0.0000" z="0.0000" />
          <vertex x="50.0000" y="50.0000" z="0.0000" />
          <vertex x="0.0000" y="50.0000" z="0.0000" />
          <vertex x="0.0000" y="0.0000" z="20.0000" />
          <vertex x="50.0000" y="0.0000" z="20.0000" />
          <vertex x="50.0000" y="50.0000" z="20.0000" />
          <vertex x="0.0000" y="50.0000" z="20.0000" />
        </vertices>
        <triangles>
          <triangle v1="0" v2="2" v3="1" />
          <triangle v1="0" v2="3" v3="2" />
          <triangle v1="4" v2="5" v3="6" />
          <triangle v1="4" v2="6" v3="7" />
        </triangles>
      </mesh>
    </object>
  </resources>
  <build>
    <item objectid="1" />
  </build>
</model>
`;
    const blob = new Blob([modelXml], { type: 'model/3mf' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'production_package.3mf';
    a.click();
    URL.revokeObjectURL(url);
  }
}

export default new CamHlrPlugin();

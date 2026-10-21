import {
  CadMeshMetadata,
  CadTessellatedSliceMetadata,
  SolidGenerationRequest,
  SubShapeSelection,
} from '../types/cad';

export interface HudCallbacks {
  onGenerate: (request: SolidGenerationRequest) => void;
  onSelectDag?: () => void;
}

export class CadHud {
  private fpsCounterEl: HTMLElement;
  private frameTimeEl: HTMLElement;
  private statVerticesEl: HTMLElement;
  private statTrianglesEl: HTMLElement;
  private statEdgesEl: HTMLElement;
  private statFacesEl: HTMLElement;

  private selectionTypeEl: HTMLElement;
  private selectionNameEl: HTMLElement;
  private selectionCoordsEl: HTMLElement;

  private solidTypeSelect: HTMLSelectElement;
  private boxControls: HTMLElement;
  private cylinderControls: HTMLElement;
  private btnGenerate: HTMLButtonElement;

  private boxWidthInput: HTMLInputElement;
  private boxHeightInput: HTMLInputElement;
  private boxDepthInput: HTMLInputElement;

  private cylRadiusInput: HTMLInputElement;
  private cylHeightInput: HTMLInputElement;

  private callbacks: HudCallbacks;

  constructor(callbacks: HudCallbacks) {
    this.callbacks = callbacks;

    this.fpsCounterEl = document.getElementById('fps-val')!;
    this.frameTimeEl = document.getElementById('frame-time-val')!;
    this.statVerticesEl = document.getElementById('stat-vertices')!;
    this.statTrianglesEl = document.getElementById('stat-triangles')!;
    this.statEdgesEl = document.getElementById('stat-edges')!;
    this.statFacesEl = document.getElementById('stat-faces')!;

    this.selectionTypeEl = document.getElementById('selection-type')!;
    this.selectionNameEl = document.getElementById('selection-name')!;
    this.selectionCoordsEl = document.getElementById('selection-coords')!;

    this.solidTypeSelect = document.getElementById('primitive-select') as HTMLSelectElement;
    this.boxControls = document.getElementById('box-controls')!;
    this.cylinderControls = document.getElementById('cylinder-controls')!;
    this.btnGenerate = document.getElementById('btn-generate') as HTMLButtonElement;

    this.boxWidthInput = document.getElementById('box-width') as HTMLInputElement;
    this.boxHeightInput = document.getElementById('box-height') as HTMLInputElement;
    this.boxDepthInput = document.getElementById('box-depth') as HTMLInputElement;

    this.cylRadiusInput = document.getElementById('cyl-radius') as HTMLInputElement;
    this.cylHeightInput = document.getElementById('cyl-height') as HTMLInputElement;

    this.setupListeners();
  }

  private setupListeners(): void {
    this.solidTypeSelect.addEventListener('change', () => {
      const type = this.solidTypeSelect.value;
      if (type === 'box') {
        this.boxControls.style.display = 'block';
        this.cylinderControls.style.display = 'none';
        this.triggerGenerate();
      } else if (type === 'cylinder') {
        this.boxControls.style.display = 'none';
        this.cylinderControls.style.display = 'block';
        this.triggerGenerate();
      } else if (type === 'dag') {
        this.boxControls.style.display = 'none';
        this.cylinderControls.style.display = 'none';
        if (this.callbacks.onSelectDag) {
          this.callbacks.onSelectDag();
        }
      }
    });

    this.btnGenerate.addEventListener('click', () => {
      this.triggerGenerate();
    });

    const triggerOnInput = (el: HTMLInputElement, valId: string) => {
      el.addEventListener('input', () => {
        const valSpan = document.getElementById(valId);
        if (valSpan) valSpan.textContent = el.value;
        this.triggerGenerate();
      });
    };

    triggerOnInput(this.boxWidthInput, 'box-width-val');
    triggerOnInput(this.boxHeightInput, 'box-height-val');
    triggerOnInput(this.boxDepthInput, 'box-depth-val');
    triggerOnInput(this.cylRadiusInput, 'cyl-radius-val');
    triggerOnInput(this.cylHeightInput, 'cyl-height-val');
  }

  public triggerGenerate(): void {
    const type = this.solidTypeSelect.value;
    if (type === 'box') {
      const width = parseFloat(this.boxWidthInput.value) || 2.0;
      const height = parseFloat(this.boxHeightInput.value) || 2.0;
      const depth = parseFloat(this.boxDepthInput.value) || 2.0;

      this.callbacks.onGenerate({
        solidType: 'box',
        params: { width, height, depth },
      });
    } else if (type === 'cylinder') {
      const radius = parseFloat(this.cylRadiusInput.value) || 1.2;
      const height = parseFloat(this.cylHeightInput.value) || 2.5;

      this.callbacks.onGenerate({
        solidType: 'cylinder',
        params: { radius, height, radialSegments: 32 },
      });
    } else if (type === 'dag') {
      if (this.callbacks.onSelectDag) {
        this.callbacks.onSelectDag();
      }
    }
  }

  public updateFps(fps: number, frameTimeMs: number): void {
    this.fpsCounterEl.textContent = fps.toFixed(1);
    this.frameTimeEl.textContent = `${frameTimeMs.toFixed(1)} ms`;
  }

  public updateMetadata(metadata: CadMeshMetadata | CadTessellatedSliceMetadata): void {
    this.statVerticesEl.textContent = metadata.vertexCount.toString();
    this.statTrianglesEl.textContent = metadata.triangleCount.toString();
    const edgeCount = 'edgeSegmentCount' in metadata ? metadata.edgeSegmentCount : metadata.edgeCount;
    this.statEdgesEl.textContent = edgeCount.toString();
    this.statFacesEl.textContent = metadata.faceCount.toString();
  }

  public updateSelection(selection: SubShapeSelection): void {
    if (selection.type === 'none') {
      this.selectionTypeEl.textContent = 'NO SELECTION';
      this.selectionTypeEl.style.color = 'var(--text-muted)';
      this.selectionNameEl.textContent = 'Hover or Click Face / Edge';
      this.selectionNameEl.style.color = 'var(--text-muted)';
      this.selectionCoordsEl.textContent = 'Coordinates: [ - , - , - ]';
      return;
    }

    if (selection.type === 'face') {
      this.selectionTypeEl.textContent = 'TOPOLOGICAL FACE';
      this.selectionTypeEl.style.color = 'var(--text-accent)';
      this.selectionNameEl.textContent = selection.label || `Face #${selection.faceId}`;
      this.selectionNameEl.style.color = 'var(--text-accent)';
      this.selectionCoordsEl.textContent = `Hit Point: [${selection.point.map((n) => n.toFixed(2)).join(', ')}]`;
    } else if (selection.type === 'edge') {
      this.selectionTypeEl.textContent = 'FEATURE EDGE';
      this.selectionTypeEl.style.color = 'var(--accent-gold)';
      this.selectionNameEl.textContent = selection.label || `Edge #${selection.edgeId}`;
      this.selectionNameEl.style.color = 'var(--accent-gold)';
      this.selectionCoordsEl.textContent = `Hit Point: [${selection.point.map((n) => n.toFixed(2)).join(', ')}]`;
    }
  }
}

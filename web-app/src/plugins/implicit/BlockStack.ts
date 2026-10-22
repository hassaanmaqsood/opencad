export interface ImplicitBlockConfig {
  partName: string;
  shellThickness: number;
  tpmsType: 'Gyroid' | 'SchwarzP' | 'SchwarzD' | 'Lidinoid' | 'Neovius';
  cellSize: number;
  wallThickness: number;
  isSheet: boolean;
  fieldSource: 'FEA Stress Field' | 'Linear Gradient' | 'Uniform';
  minThickness: number;
  maxThickness: number;
  octreeDepth: number;
  crossSectionZ: number;
  showCrossSection: boolean;
}

export class BlockStackUi {
  private container: HTMLElement;
  private config: ImplicitBlockConfig;
  private onChange: (config: ImplicitBlockConfig) => void;

  constructor(
    container: HTMLElement,
    initialConfig: ImplicitBlockConfig,
    onChange: (config: ImplicitBlockConfig) => void
  ) {
    this.container = container;
    this.config = { ...initialConfig };
    this.onChange = onChange;
    this.render();
  }

  public setConfig(newConfig: Partial<ImplicitBlockConfig>): void {
    this.config = { ...this.config, ...newConfig };
    this.render();
  }

  public getConfig(): ImplicitBlockConfig {
    return { ...this.config };
  }

  public render(): void {
    this.container.innerHTML = `
      <div class="ntop-notebook-container" data-testid="ntop-block-stack">
        <div class="ntop-header">
          <span class="ntop-title">🧬 Field Graph / Block Stack</span>
          <span class="ntop-badge">nTop Mode</span>
        </div>

        <!-- Block 1: Input Body & Shell -->
        <div class="ntop-block" data-testid="block-input-body">
          <div class="ntop-block-title">
            <span class="ntop-block-icon">🧱</span>
            <span class="ntop-block-name">1. Solid Body Shell</span>
          </div>
          <div class="ntop-block-body">
            <div class="ntop-row">
              <label>Body Reference:</label>
              <span class="ntop-ref-pill">${this.config.partName}</span>
            </div>
            <div class="ntop-row">
              <label>Shell Skin (mm):</label>
              <input type="number" id="ntop-shell-thickness" class="ntop-input" min="0.5" max="10.0" step="0.5" value="${this.config.shellThickness}" data-testid="input-shell-thickness">
            </div>
          </div>
        </div>

        <!-- Block 2: TPMS Minimal Surface Lattice -->
        <div class="ntop-block" data-testid="block-tpms-lattice">
          <div class="ntop-block-title">
            <span class="ntop-block-icon">🕸️</span>
            <span class="ntop-block-name">2. TPMS Implicit Lattice</span>
          </div>
          <div class="ntop-block-body">
            <div class="ntop-row">
              <label>Lattice Type:</label>
              <select id="ntop-tpms-type" class="ntop-select" data-testid="select-tpms-type">
                <option value="Gyroid" ${this.config.tpmsType === 'Gyroid' ? 'selected' : ''}>Gyroid Minimal Surface</option>
                <option value="SchwarzP" ${this.config.tpmsType === 'SchwarzP' ? 'selected' : ''}>Schwarz P (Primitive)</option>
                <option value="SchwarzD" ${this.config.tpmsType === 'SchwarzD' ? 'selected' : ''}>Schwarz D (Diamond)</option>
                <option value="Lidinoid" ${this.config.tpmsType === 'Lidinoid' ? 'selected' : ''}>Lidinoid Level Set</option>
                <option value="Neovius" ${this.config.tpmsType === 'Neovius' ? 'selected' : ''}>Neovius Minimal Surface</option>
              </select>
            </div>
            <div class="ntop-row">
              <label>Cell Wavelength (mm):</label>
              <input type="range" id="ntop-cell-size" class="ntop-slider" min="4.0" max="30.0" step="1.0" value="${this.config.cellSize}" data-testid="slider-cell-size">
              <span class="ntop-val" id="val-cell-size">${this.config.cellSize} mm</span>
            </div>
            <div class="ntop-row">
              <label>Base Thickness (mm):</label>
              <input type="number" id="ntop-wall-thickness" class="ntop-input" min="0.2" max="5.0" step="0.1" value="${this.config.wallThickness}" data-testid="input-wall-thickness">
            </div>
          </div>
        </div>

        <!-- Block 3: Field Modulator -->
        <div class="ntop-block" data-testid="block-field-modulator">
          <div class="ntop-block-title">
            <span class="ntop-block-icon">📈</span>
            <span class="ntop-block-name">3. Field Modulator</span>
          </div>
          <div class="ntop-block-body">
            <div class="ntop-row">
              <label>Driver Source:</label>
              <select id="ntop-field-source" class="ntop-select" data-testid="select-field-source">
                <option value="FEA Stress Field" ${this.config.fieldSource === 'FEA Stress Field' ? 'selected' : ''}>Wave 8 FEA Von Mises Stress</option>
                <option value="Linear Gradient" ${this.config.fieldSource === 'Linear Gradient' ? 'selected' : ''}>Linear Z Height Gradient</option>
                <option value="Uniform" ${this.config.fieldSource === 'Uniform' ? 'selected' : ''}>Uniform Constant Thickness</option>
              </select>
            </div>
            <div class="ntop-row">
              <label>Min Thickness (mm):</label>
              <input type="number" id="ntop-min-thick" class="ntop-input" min="0.2" max="3.0" step="0.1" value="${this.config.minThickness}" data-testid="input-min-thickness">
            </div>
            <div class="ntop-row">
              <label>Max Thickness (mm):</label>
              <input type="number" id="ntop-max-thick" class="ntop-input" min="1.0" max="8.0" step="0.1" value="${this.config.maxThickness}" data-testid="input-max-thickness">
            </div>
          </div>
        </div>

        <!-- Block 4: Scalar Field Cross-Section Plane & Slicing -->
        <div class="ntop-block" data-testid="block-preview-slicing">
          <div class="ntop-block-title">
            <span class="ntop-block-icon">🔍</span>
            <span class="ntop-block-name">4. Real-Time Scalar Plane & Meshing</span>
          </div>
          <div class="ntop-block-body">
            <div class="ntop-row">
              <label>Cross-Section Shader:</label>
              <input type="checkbox" id="ntop-toggle-plane" ${this.config.showCrossSection ? 'checked' : ''} data-testid="toggle-cross-section">
            </div>
            <div class="ntop-row">
              <label>Plane Elevation Z (mm):</label>
              <input type="range" id="ntop-plane-z" class="ntop-slider" min="-30" max="30" step="1" value="${this.config.crossSectionZ}" data-testid="slider-cross-section-z">
              <span class="ntop-val" id="val-plane-z">${this.config.crossSectionZ} mm</span>
            </div>
            <div class="ntop-row">
              <label>Dual Contouring Depth:</label>
              <select id="ntop-octree-depth" class="ntop-select" data-testid="select-octree-depth">
                <option value="3" ${this.config.octreeDepth === 3 ? 'selected' : ''}>Fast Preview (Depth 3)</option>
                <option value="4" ${this.config.octreeDepth === 4 ? 'selected' : ''}>Balanced (Depth 4)</option>
                <option value="5" ${this.config.octreeDepth === 5 ? 'selected' : ''}>High Precision (Depth 5)</option>
              </select>
            </div>
          </div>
        </div>

        <!-- Live Code-CAD Syntax Output -->
        <div class="ntop-code-box" data-testid="ntop-code-syntax">
          <span class="ntop-code-label">Fluent Code-CAD API:</span>
          <code>part.shell(${this.config.shellThickness.toFixed(1)}).infill(tpms.${this.config.tpmsType.toLowerCase()}({ period: ${this.config.cellSize.toFixed(1)}, thickness: field.fromStress(feaResult, ${this.config.minThickness.toFixed(1)}, ${this.config.maxThickness.toFixed(1)}) }))</code>
        </div>
      </div>
    `;

    this.attachEventListeners();
  }

  private attachEventListeners(): void {
    const shellInput = this.container.querySelector('#ntop-shell-thickness') as HTMLInputElement;
    shellInput?.addEventListener('change', (e) => {
      this.config.shellThickness = parseFloat((e.target as HTMLInputElement).value) || 2.0;
      this.notify();
    });

    const tpmsSelect = this.container.querySelector('#ntop-tpms-type') as HTMLSelectElement;
    tpmsSelect?.addEventListener('change', (e) => {
      this.config.tpmsType = (e.target as HTMLSelectElement).value as any;
      this.notify();
    });

    const cellSizeSlider = this.container.querySelector('#ntop-cell-size') as HTMLInputElement;
    const cellSizeVal = this.container.querySelector('#val-cell-size') as HTMLElement;
    cellSizeSlider?.addEventListener('input', (e) => {
      const v = parseFloat((e.target as HTMLInputElement).value);
      this.config.cellSize = v;
      if (cellSizeVal) cellSizeVal.textContent = `${v} mm`;
      this.notify();
    });

    const wallInput = this.container.querySelector('#ntop-wall-thickness') as HTMLInputElement;
    wallInput?.addEventListener('change', (e) => {
      this.config.wallThickness = parseFloat((e.target as HTMLInputElement).value) || 1.0;
      this.notify();
    });

    const fieldSourceSelect = this.container.querySelector('#ntop-field-source') as HTMLSelectElement;
    fieldSourceSelect?.addEventListener('change', (e) => {
      this.config.fieldSource = (e.target as HTMLSelectElement).value as any;
      this.notify();
    });

    const minThickInput = this.container.querySelector('#ntop-min-thick') as HTMLInputElement;
    minThickInput?.addEventListener('change', (e) => {
      this.config.minThickness = parseFloat((e.target as HTMLInputElement).value) || 0.8;
      this.notify();
    });

    const maxThickInput = this.container.querySelector('#ntop-max-thick') as HTMLInputElement;
    maxThickInput?.addEventListener('change', (e) => {
      this.config.maxThickness = parseFloat((e.target as HTMLInputElement).value) || 2.5;
      this.notify();
    });

    const togglePlane = this.container.querySelector('#ntop-toggle-plane') as HTMLInputElement;
    togglePlane?.addEventListener('change', (e) => {
      this.config.showCrossSection = (e.target as HTMLInputElement).checked;
      this.notify();
    });

    const planeZSlider = this.container.querySelector('#ntop-plane-z') as HTMLInputElement;
    const planeZVal = this.container.querySelector('#val-plane-z') as HTMLElement;
    planeZSlider?.addEventListener('input', (e) => {
      const v = parseFloat((e.target as HTMLInputElement).value);
      this.config.crossSectionZ = v;
      if (planeZVal) planeZVal.textContent = `${v} mm`;
      this.notify();
    });

    const depthSelect = this.container.querySelector('#ntop-octree-depth') as HTMLSelectElement;
    depthSelect?.addEventListener('change', (e) => {
      this.config.octreeDepth = parseInt((e.target as HTMLSelectElement).value, 10) || 4;
      this.notify();
    });
  }

  private notify(): void {
    this.onChange(this.config);
    // Update live Code-CAD snippet display
    const codeElem = this.container.querySelector('.ntop-code-box code');
    if (codeElem) {
      codeElem.textContent = `part.shell(${this.config.shellThickness.toFixed(1)}).infill(tpms.${this.config.tpmsType.toLowerCase()}({ period: ${this.config.cellSize.toFixed(1)}, thickness: field.fromStress(feaResult, ${this.config.minThickness.toFixed(1)}, ${this.config.maxThickness.toFixed(1)}) }))`;
    }
  }
}

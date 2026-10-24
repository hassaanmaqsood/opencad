/**
 * @file lil_controller.ts
 * 100% Code-Configured Floating GUI Controller for OpenCAD.
 * Provides a lightweight, 260px wide floating dark-theme panel matching lil-gui ergonomics.
 * Replaces all GUI modeling chrome with a declarative controller driven entirely by Code-CAD config.
 */

export interface LilParamDef {
  value: number | boolean | string;
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
  label?: string;
}

export interface LilControllerConfig {
  title?: string;
  sliders?: boolean;
  share?: string[];
  lenses?: string[];
  actions?: string[];
  params?: Record<string, number | boolean | string | LilParamDef>;
  telemetry?: Record<string, string | number>;
  onParamChange?: (name: string, value: any) => void;
  onLensToggle?: (lensId: string, active: boolean) => void;
  onAction?: (actionId: string) => void;
}

const DEFAULT_LENSES = [
  { id: 'solid', label: 'Solid Mesh', default: true },
  { id: 'wireframe', label: 'Wireframe', default: false },
  { id: 'section_aa', label: 'Section A-A', default: false },
  { id: 'zebra', label: 'Zebra Stripes', default: false },
  { id: 'fea_stress', label: 'FEA Stress Colormap', default: false },
  { id: 'fact_flexure', label: 'FACT Flexure Screws', default: false },
  { id: 'sheet_unfold', label: 'Sheet Metal Unfold', default: false },
  { id: 'cam_toolpath', label: 'CAM Toolpath', default: false },
  { id: 'blueprint_2d', label: '2D Blueprint Drawing', default: false },
];

const DEFAULT_ACTIONS = [
  { id: 'exportSTL', label: '📥 Export STL (Watertight)' },
  { id: 'exportSTEP', label: '📄 Export STEP (AP214)' },
  { id: 'export3MF', label: '📦 Export 3MF Build' },
  { id: 'exportDXF', label: '📐 Export DXF Drawing' },
  { id: 'exportSVG', label: '🖼 Export SVG Vector' },
  { id: 'exportGCode', label: '⚙ Export CNC G-Code' },
  { id: 'copyShareUrl', label: '🔗 Copy Share URL' },
];

export class LilController {
  private container: HTMLElement;
  private config: LilControllerConfig;
  private rootEl: HTMLElement;
  private params: Record<string, any> = {};
  private activeLenses: Set<string> = new Set(['solid']);
  private folderStates: Record<string, boolean> = {
    parameters: true,
    telemetry: true,
    lenses: true,
    actions: true,
  };

  constructor(parent: HTMLElement | string, config: LilControllerConfig = {}) {
    this.container = typeof parent === 'string'
      ? (document.querySelector(parent) as HTMLElement) || document.body
      : parent;

    this.config = {
      title: 'OpenCAD Controller',
      sliders: true,
      ...config,
    };

    if (this.config.params) {
      for (const [k, v] of Object.entries(this.config.params)) {
        this.params[k] = typeof v === 'object' && v !== null && 'value' in v ? v.value : v;
      }
    }

    this.rootEl = document.createElement('div');
    this.rootEl.className = 'lil-controller';
    this.rootEl.setAttribute('data-testid', 'lil-controller');
    this.container.appendChild(this.rootEl);

    this.render();
  }

  public setConfig(newConfig: Partial<LilControllerConfig>): void {
    this.config = { ...this.config, ...newConfig };
    if (newConfig.params) {
      for (const [k, v] of Object.entries(newConfig.params)) {
        this.params[k] = typeof v === 'object' && v !== null && 'value' in v ? v.value : v;
      }
    }
    this.render();
  }

  public updateTelemetry(telemetry: Record<string, string | number>): void {
    this.config.telemetry = { ...(this.config.telemetry || {}), ...telemetry };
    const telFolder = this.rootEl.querySelector('[data-testid="lil-folder-telemetry"] .lil-folder-children');
    if (telFolder) {
      telFolder.innerHTML = this.renderTelemetryRows();
    }
  }

  public setParam(name: string, value: any): void {
    this.params[name] = value;
    const input = this.rootEl.querySelector(`[data-testid="lil-param-input-${name}"]`) as HTMLInputElement | null;
    const slider = this.rootEl.querySelector(`[data-testid="lil-param-slider-${name}"]`) as HTMLInputElement | null;
    if (input) input.value = String(value);
    if (slider) slider.value = String(value);
  }

  public getParams(): Record<string, any> {
    return { ...this.params };
  }

  public getRootElement(): HTMLElement {
    return this.rootEl;
  }

  public show(): void {
    this.rootEl.style.display = 'block';
  }

  public hide(): void {
    this.rootEl.style.display = 'none';
  }

  public destroy(): void {
    this.rootEl.remove();
  }

  private toggleFolder(folderId: string): void {
    this.folderStates[folderId] = !this.folderStates[folderId];
    const folder = this.rootEl.querySelector(`[data-testid="lil-folder-${folderId}"]`);
    if (folder) {
      const children = folder.querySelector('.lil-folder-children') as HTMLElement | null;
      const chevron = folder.querySelector('.lil-chevron') as HTMLElement | null;
      if (children) {
        children.style.display = this.folderStates[folderId] ? 'flex' : 'none';
      }
      if (chevron) {
        chevron.textContent = this.folderStates[folderId] ? '▼' : '▶';
      }
    }
  }

  private render(): void {
    this.rootEl.innerHTML = '';

    // Title Bar
    const titleBar = document.createElement('div');
    titleBar.className = 'lil-titlebar';
    titleBar.innerHTML = `
      <div class="lil-title"><span class="lil-dot"></span>${this.config.title || 'OpenCAD Controller'}</div>
      <div class="lil-close" title="Collapse Controller">−</div>
    `;
    titleBar.querySelector('.lil-close')?.addEventListener('click', () => {
      const isCollapsed = this.rootEl.classList.toggle('lil-collapsed');
      const closeBtn = titleBar.querySelector('.lil-close');
      if (closeBtn) closeBtn.textContent = isCollapsed ? '+' : '−';
    });
    this.rootEl.appendChild(titleBar);

    // 1. Parameters Folder (if sliders enabled and params defined)
    const showSliders = this.config.sliders !== false;
    const hasParams = this.config.params && Object.keys(this.config.params).length > 0;
    if (showSliders && hasParams) {
      this.rootEl.appendChild(this.createParametersFolder());
    }

    // 2. Telemetry / CAE / CAM Folder
    const shareKeys = this.config.share;
    const hasTelemetry = shareKeys !== undefined
      ? shareKeys.length > 0
      : (this.config.telemetry && Object.keys(this.config.telemetry).length > 0);
    if (hasTelemetry) {
      this.rootEl.appendChild(this.createTelemetryFolder());
    }

    // 3. View & Lenses Folder
    this.rootEl.appendChild(this.createLensesFolder());

    // 4. Actions & Exports Folder
    this.rootEl.appendChild(this.createActionsFolder());
  }

  private createParametersFolder(): HTMLElement {
    const folder = document.createElement('div');
    folder.className = 'lil-folder';
    folder.setAttribute('data-testid', 'lil-folder-parameters');

    const isOpen = this.folderStates.parameters;
    const header = document.createElement('div');
    header.className = 'lil-folder-header';
    header.innerHTML = `<span class="lil-chevron">${isOpen ? '▼' : '▶'}</span> Parameters`;
    header.addEventListener('click', () => this.toggleFolder('parameters'));
    folder.appendChild(header);

    const children = document.createElement('div');
    children.className = 'lil-folder-children';
    children.style.display = isOpen ? 'flex' : 'none';

    if (this.config.params) {
      for (const [key, rawVal] of Object.entries(this.config.params)) {
        const def: LilParamDef = typeof rawVal === 'object' && rawVal !== null && 'value' in rawVal
          ? rawVal as LilParamDef
          : { value: rawVal };

        const row = document.createElement('div');
        row.className = 'lil-param-row';
        row.setAttribute('data-testid', `lil-param-${key}`);

        const label = document.createElement('label');
        label.className = 'lil-param-label';
        label.textContent = def.label || key;
        row.appendChild(label);

        const val = this.params[key];

        if (typeof def.value === 'boolean' || typeof val === 'boolean') {
          const checkbox = document.createElement('input');
          checkbox.type = 'checkbox';
          checkbox.className = 'lil-checkbox';
          checkbox.checked = Boolean(val);
          checkbox.setAttribute('data-testid', `lil-param-input-${key}`);
          checkbox.addEventListener('change', () => {
            this.params[key] = checkbox.checked;
            this.config.onParamChange?.(key, checkbox.checked);
          });
          row.appendChild(checkbox);
        } else if (typeof def.value === 'number' || typeof val === 'number') {
          const controlWrap = document.createElement('div');
          controlWrap.className = 'lil-number-wrap';

          const min = def.min ?? 0;
          const max = def.max ?? (Number(val) > 100 ? Number(val) * 2 : 100);
          const step = def.step ?? (max - min <= 10 ? 0.1 : 1);

          const slider = document.createElement('input');
          slider.type = 'range';
          slider.className = 'lil-slider';
          slider.min = String(min);
          slider.max = String(max);
          slider.step = String(step);
          slider.value = String(val);
          slider.setAttribute('data-testid', `lil-param-slider-${key}`);

          const numInput = document.createElement('input');
          numInput.type = 'number';
          numInput.className = 'lil-number-input';
          numInput.min = String(min);
          numInput.max = String(max);
          numInput.step = String(step);
          numInput.value = String(val);
          numInput.setAttribute('data-testid', `lil-param-input-${key}`);

          slider.addEventListener('input', () => {
            const num = parseFloat(slider.value);
            numInput.value = slider.value;
            this.params[key] = num;
            this.config.onParamChange?.(key, num);
          });

          numInput.addEventListener('change', () => {
            const num = parseFloat(numInput.value);
            slider.value = numInput.value;
            this.params[key] = num;
            this.config.onParamChange?.(key, num);
          });

          controlWrap.appendChild(slider);
          controlWrap.appendChild(numInput);
          row.appendChild(controlWrap);
        } else {
          const textInput = document.createElement('input');
          textInput.type = 'text';
          textInput.className = 'lil-text-input';
          textInput.value = String(val ?? '');
          textInput.setAttribute('data-testid', `lil-param-input-${key}`);
          textInput.addEventListener('change', () => {
            this.params[key] = textInput.value;
            this.config.onParamChange?.(key, textInput.value);
          });
          row.appendChild(textInput);
        }

        children.appendChild(row);
      }
    }

    folder.appendChild(children);
    return folder;
  }

  private createTelemetryFolder(): HTMLElement {
    const folder = document.createElement('div');
    folder.className = 'lil-folder';
    folder.setAttribute('data-testid', 'lil-folder-telemetry');

    const isOpen = this.folderStates.telemetry;
    const header = document.createElement('div');
    header.className = 'lil-folder-header';
    header.innerHTML = `<span class="lil-chevron">${isOpen ? '▼' : '▶'}</span> Telemetry / CAE / CAM`;
    header.addEventListener('click', () => this.toggleFolder('telemetry'));
    folder.appendChild(header);

    const children = document.createElement('div');
    children.className = 'lil-folder-children';
    children.style.display = isOpen ? 'flex' : 'none';
    children.innerHTML = this.renderTelemetryRows();

    folder.appendChild(children);
    return folder;
  }

  private renderTelemetryRows(): string {
    const tel = this.config.telemetry || {
      'Mass': '216.0 g',
      'Volume': '80,000 mm³',
      'Bounding Box': '80 × 50 × 20 mm',
      'Max Stress': '142.6 MPa',
      'Compliance C11': '1.45e-4 mm/N',
      'CNC Runtime': '3.5 min',
    };

    let html = '';
    for (const [k, v] of Object.entries(tel)) {
      html += `
        <div class="lil-telemetry-row">
          <span class="lil-telemetry-key">${k}</span>
          <span class="lil-telemetry-val">${v}</span>
        </div>
      `;
    }
    return html;
  }

  private createLensesFolder(): HTMLElement {
    const folder = document.createElement('div');
    folder.className = 'lil-folder';
    folder.setAttribute('data-testid', 'lil-folder-lenses');

    const isOpen = this.folderStates.lenses;
    const header = document.createElement('div');
    header.className = 'lil-folder-header';
    header.innerHTML = `<span class="lil-chevron">${isOpen ? '▼' : '▶'}</span> View & Lenses`;
    header.addEventListener('click', () => this.toggleFolder('lenses'));
    folder.appendChild(header);

    const children = document.createElement('div');
    children.className = 'lil-folder-children';
    children.style.display = isOpen ? 'flex' : 'none';

    const allowed = this.config.lenses;
    const lensesToRender = allowed
      ? DEFAULT_LENSES.filter((l) => allowed.includes(l.id))
      : DEFAULT_LENSES;

    for (const lens of lensesToRender) {
      const row = document.createElement('div');
      row.className = 'lil-lens-row';

      const label = document.createElement('label');
      label.className = 'lil-lens-label';
      label.textContent = lens.label;

      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.className = 'lil-checkbox';
      checkbox.checked = this.activeLenses.has(lens.id);
      checkbox.setAttribute('data-testid', `lil-lens-${lens.id}`);

      checkbox.addEventListener('change', () => {
        if (checkbox.checked) {
          this.activeLenses.add(lens.id);
        } else {
          this.activeLenses.delete(lens.id);
        }
        this.config.onLensToggle?.(lens.id, checkbox.checked);
      });

      row.appendChild(label);
      row.appendChild(checkbox);
      children.appendChild(row);
    }

    folder.appendChild(children);
    return folder;
  }

  private createActionsFolder(): HTMLElement {
    const folder = document.createElement('div');
    folder.className = 'lil-folder';
    folder.setAttribute('data-testid', 'lil-folder-actions');

    const isOpen = this.folderStates.actions;
    const header = document.createElement('div');
    header.className = 'lil-folder-header';
    header.innerHTML = `<span class="lil-chevron">${isOpen ? '▼' : '▶'}</span> Actions & Exports`;
    header.addEventListener('click', () => this.toggleFolder('actions'));
    folder.appendChild(header);

    const children = document.createElement('div');
    children.className = 'lil-folder-children';
    children.style.display = isOpen ? 'flex' : 'none';

    const allowedActions = this.config.actions;
    const actionsToRender = allowedActions
      ? DEFAULT_ACTIONS.filter((a) => allowedActions.includes(a.id))
      : DEFAULT_ACTIONS;

    for (const act of actionsToRender) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'lil-action-btn';
      btn.setAttribute('data-testid', `lil-action-${act.id}`);
      btn.textContent = act.label;

      btn.addEventListener('click', () => {
        btn.classList.add('lil-btn-clicked');
        setTimeout(() => btn.classList.remove('lil-btn-clicked'), 200);
        this.config.onAction?.(act.id);
      });

      children.appendChild(btn);
    }

    folder.appendChild(children);
    return folder;
  }
}

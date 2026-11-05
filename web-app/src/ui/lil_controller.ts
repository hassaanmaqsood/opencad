/**
 * @file lil_controller.ts
 * 100% Code-Configured Floating GUI Controller for OpenCAD.
 * Provides a lightweight, 260px wide floating dark-theme panel matching lil-gui ergonomics.
 * Replaces all GUI modeling chrome with a declarative controller driven entirely by Code-CAD / CDML config.
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
  gui?: boolean;
  title?: string;
  sliders?: boolean;
  vars?: string[];
  probes?: string[];
  exports?: string[];
  share?: string[];
  lenses?: string[];
  actions?: string[];
  params?: Record<string, number | boolean | string | LilParamDef>;
  telemetry?: Record<string, string | number>;
  probeValues?: Record<string, number | string>;
  onParamChange?: (name: string, value: any) => void;
  onLensToggle?: (lensId: string, active: boolean) => void;
  onAction?: (actionId: string) => void;
}

export class LilController {
  private container: HTMLElement;
  private config: LilControllerConfig;
  private rootEl: HTMLElement;
  private params: Record<string, any> = {};
  private folderStates: Record<string, boolean> = {
    parameters: true,
    probes: true,
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
      gui: true,
      ...config,
    };

    if (this.config.params) {
      for (const [k, v] of Object.entries(this.config.params)) {
        this.params[k] = typeof v === 'object' && v !== null && 'value' in v ? v.value : v;
      }
    }

    this.rootEl = document.createElement('div');
    this.rootEl.className = 'lil-gui lil-controller';
    this.rootEl.setAttribute('data-testid', 'lil-controller');

    if (this.config.gui !== false) {
      this.container.appendChild(this.rootEl);
      this.render();
    }
  }

  public setConfig(newConfig: Partial<LilControllerConfig>): void {
    this.config = { ...this.config, ...newConfig };
    if (newConfig.params) {
      for (const [k, v] of Object.entries(newConfig.params)) {
        this.params[k] = typeof v === 'object' && v !== null && 'value' in v ? v.value : v;
      }
    }

    if (this.config.gui === false) {
      this.destroy();
      return;
    }

    if (!this.rootEl.parentElement) {
      this.container.appendChild(this.rootEl);
    }
    this.render();
  }

  public updateProbes(probes: Record<string, number | string>): void {
    this.config.probeValues = { ...(this.config.probeValues || {}), ...probes };
    for (const [k, v] of Object.entries(probes)) {
      const el = this.rootEl.querySelector(`[data-testid="lil-probe-${k}"] .lil-stat-value`) as HTMLElement | null;
      if (el) {
        el.textContent = typeof v === 'number' ? v.toFixed(2) : String(v);
      }
    }
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
      if (children) {
        children.style.display = this.folderStates[folderId] ? 'flex' : 'none';
      }
      const chevron = folder.querySelector('.lil-chevron');
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
    let paramEntries = Object.entries(this.config.params || {});
    if (this.config.vars && this.config.vars.length > 0) {
      const allowedVars = new Set(this.config.vars);
      paramEntries = paramEntries.filter(([k]) => allowedVars.has(k));
    }

    if (showSliders && paramEntries.length > 0) {
      this.rootEl.appendChild(this.createParametersFolder(paramEntries));
    }

    // 2. Probes Live Monitors Folder
    const probeKeys = this.config.probes;
    if (probeKeys && probeKeys.length > 0) {
      this.rootEl.appendChild(this.createProbesFolder(probeKeys));
    }

    // 3. Actions & Exports Folder
    const hasExports = (this.config.exports && this.config.exports.length > 0) || (this.config.actions && this.config.actions.length > 0);
    if (hasExports) {
      this.rootEl.appendChild(this.createActionsFolder());
    }
  }

  private createParametersFolder(paramEntries: [string, any][]): HTMLElement {
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

    for (const [key, rawVal] of paramEntries) {
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

      const val = this.params[key] ?? def.value;

      const controlWrap = document.createElement('div');
      controlWrap.className = 'lil-number-wrap';

      const min = def.min ?? (Number(val) < 0 ? Number(val) * 2 : 0);
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
      children.appendChild(row);
    }

    folder.appendChild(children);
    return folder;
  }

  private createProbesFolder(probeKeys: string[]): HTMLElement {
    const folder = document.createElement('div');
    folder.className = 'lil-folder';
    folder.setAttribute('data-testid', 'lil-folder-probes');

    const isOpen = this.folderStates.probes;
    const header = document.createElement('div');
    header.className = 'lil-folder-header';
    header.innerHTML = `<span class="lil-chevron">${isOpen ? '▼' : '▶'}</span> Probes & Quantities`;
    header.addEventListener('click', () => this.toggleFolder('probes'));
    folder.appendChild(header);

    const children = document.createElement('div');
    children.className = 'lil-folder-children';
    children.style.display = isOpen ? 'flex' : 'none';

    for (const pid of probeKeys) {
      const row = document.createElement('div');
      row.className = 'lil-param-row lil-probe-row';
      row.setAttribute('data-testid', `lil-probe-${pid}`);

      const label = document.createElement('label');
      label.className = 'lil-param-label';
      label.textContent = pid;

      const valSpan = document.createElement('span');
      valSpan.className = 'lil-stat-value';
      const rawVal = this.config.probeValues?.[pid];
      valSpan.textContent = typeof rawVal === 'number' ? rawVal.toFixed(2) : (rawVal ? String(rawVal) : '—');

      row.appendChild(label);
      row.appendChild(valSpan);
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
    header.innerHTML = `<span class="lil-chevron">${isOpen ? '▼' : '▶'}</span> Exports`;
    header.addEventListener('click', () => this.toggleFolder('actions'));
    folder.appendChild(header);

    const children = document.createElement('div');
    children.className = 'lil-folder-children';
    children.style.display = isOpen ? 'flex' : 'none';

    const reqExports = this.config.exports || this.config.actions || ['step', 'stl'];
    const lowerReqs = reqExports.map(e => e.toLowerCase().replace(/^export/, ''));

    for (const exp of lowerReqs) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'lil-action-btn';
      btn.setAttribute('data-testid', `lil-action-${exp}`);
      btn.textContent = `Export ${exp.toUpperCase()}`;

      btn.addEventListener('click', () => {
        btn.classList.add('lil-btn-clicked');
        setTimeout(() => btn.classList.remove('lil-btn-clicked'), 200);
        this.config.onAction?.(exp);
      });

      children.appendChild(btn);
    }

    folder.appendChild(children);
    return folder;
  }

  private renderTelemetryRows(): string {
    const tel = this.config.telemetry || {};
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
}

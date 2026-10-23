/**
 * @file parameter_sliders.ts
 * Auto-Generated Parameter Sliders for Non-Dev Makers.
 * Parses top-level parameters from .ocad.ts scripts and renders interactive UI sliders
 * with direct one-click download buttons (STEP / 3MF / DXF).
 */

export interface ModelParam {
  name: string;
  value: number;
  min: number;
  max: number;
  step: number;
}

export class ParameterSlidersPanel {
  private container: HTMLElement;
  private params: Map<string, ModelParam> = new Map();
  public onParamChange: (name: string, value: number) => void;
  private onDownloadStep?: () => void;
  private onDownload3mf?: () => void;
  private onDownloadDxf?: () => void;

  constructor(options: {
    containerId?: string;
    onParamChange: (name: string, value: number) => void;
    onDownloadStep?: () => void;
    onDownload3mf?: () => void;
    onDownloadDxf?: () => void;
  }) {
    this.container = document.getElementById(options.containerId || 'parameter-sliders-panel')!;
    this.onParamChange = options.onParamChange;
    this.onDownloadStep = options.onDownloadStep;
    this.onDownload3mf = options.onDownload3mf;
    this.onDownloadDxf = options.onDownloadDxf;
  }

  /**
   * Parses parameters from an .ocad.ts code string.
   */
  public static parseCode(code: string): ModelParam[] {
    const list: ModelParam[] = [];
    const seen = new Set<string>();

    // 1. Look for `export const params = { ... }` or `const params = { ... }`
    const paramsBlockMatch = code.match(/(?:export\s+)?const\s+params\s*=\s*\{([\s\S]*?)\};/);
    if (paramsBlockMatch) {
      const body = paramsBlockMatch[1];
      const entryRegex = /([a-zA-Z0-9_]+)\s*:\s*(-?[0-9]+(?:\.[0-9]+)?)/g;
      let m: RegExpExecArray | null;
      while ((m = entryRegex.exec(body)) !== null) {
        const name = m[1];
        const val = parseFloat(m[2]);
        if (!isNaN(val) && !seen.has(name)) {
          seen.add(name);
          const min = val > 0 ? Math.max(0.5, Math.round(val * 0.2 * 10) / 10) : val * 2;
          const max = val > 0 ? Math.max(10, Math.round(val * 3.0 * 10) / 10) : 0;
          const step = val >= 10 ? 1 : 0.1;
          list.push({ name, value: val, min, max, step });
        }
      }
    }

    // 2. Look for top-level `const width = 50;` etc.
    const topLevelRegex = /(?:export\s+)?const\s+([a-zA-Z0-9_]+)\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)\s*;/g;
    let m2: RegExpExecArray | null;
    while ((m2 = topLevelRegex.exec(code)) !== null) {
      const name = m2[1];
      if (name === 'params' || name === 'THREE' || name === 'Math' || seen.has(name)) continue;
      const val = parseFloat(m2[2]);
      if (!isNaN(val)) {
        seen.add(name);
        const min = val > 0 ? Math.max(0.5, Math.round(val * 0.2 * 10) / 10) : val * 2;
        const max = val > 0 ? Math.max(10, Math.round(val * 3.0 * 10) / 10) : 0;
        const step = val >= 10 ? 1 : 0.1;
        list.push({ name, value: val, min, max, step });
      }
    }

    return list;
  }

  /**
   * Replaces a parameter value in the code string.
   */
  public static updateCode(code: string, name: string, value: number): string {
    // Check inside `params = { ... }`
    const inParamsRegex = new RegExp(`(${name}\\s*:\\s*)-?[0-9]+(?:\\.[0-9]+)?`, 'g');
    if (inParamsRegex.test(code)) {
      return code.replace(inParamsRegex, `$1${value}`);
    }

    // Check top level `const name = ...;`
    const topLevelRegex = new RegExp(`((?:export\\s+)?const\\s+${name}\\s*=\\s*)-?[0-9]+(?:\\.[0-9]+)?`, 'g');
    if (topLevelRegex.test(code)) {
      return code.replace(topLevelRegex, `$1${value}`);
    }

    return code;
  }

  public setParams(params: ModelParam[]) {
    this.params.clear();
    for (const p of params) {
      this.params.set(p.name, { ...p });
    }
    this.render();
  }

  public setVisible(visible: boolean) {
    if (this.container) {
      this.container.style.display = visible ? 'block' : 'none';
    }
  }

  public setParam(name: string, value: number) {
    let p = this.params.get(name);
    if (!p) {
      p = { name, value, min: Math.min(0.5, Math.floor(value)), max: Math.max(10, Math.ceil(value * 2)), step: value % 1 !== 0 ? 0.1 : 1 };
      this.params.set(name, p);
    } else {
      p.value = value;
      if (value < p.min) p.min = Math.min(p.min, Math.floor(value));
      if (value > p.max) p.max = Math.max(p.max, Math.ceil(value * 1.5));
      if (value % 1 !== 0) p.step = 0.1;
    }
    const slider = document.getElementById(`param-slider-${name}`) as HTMLInputElement | null;
    if (slider) {
      slider.min = p.min.toString();
      slider.max = p.max.toString();
      slider.step = (p.step ?? 0.1).toString();
      slider.value = value.toString();
    }
    const input = document.getElementById(`param-input-${name}`) as HTMLInputElement | null;
    if (input) input.value = value.toString();

    const valEl = document.getElementById(`param-val-${name}`);
    if (valEl) valEl.textContent = value.toString();

    this.onParamChange(name, value);
  }

  public getParam(name: string): number | undefined {
    return this.params.get(name)?.value;
  }

  private render() {
    if (!this.container) return;
    if (this.params.size === 0) {
      this.container.style.display = 'none';
      return;
    }

    this.container.style.display = 'block';
    this.container.innerHTML = '';

    const header = document.createElement('div');
    header.className = 'hud-section-title';
    header.style.display = 'flex';
    header.style.alignItems = 'center';
    header.style.justifyContent = 'space-between';
    header.innerHTML = `
      <span>⚙️ Parameters</span>
      <span style="font-size: 11px; opacity: 0.7; font-weight: normal;">Maker Mode</span>
    `;
    this.container.appendChild(header);

    const controlsContainer = document.createElement('div');
    controlsContainer.className = 'parameter-controls-list';
    controlsContainer.style.display = 'flex';
    controlsContainer.style.flexDirection = 'column';
    controlsContainer.style.gap = '8px';
    controlsContainer.style.marginTop = '8px';

    for (const [name, p] of this.params.entries()) {
      const group = document.createElement('div');
      group.className = 'control-group';
      group.style.marginBottom = '6px';

      const row = document.createElement('div');
      row.className = 'control-row';
      row.innerHTML = `
        <label for="param-slider-${name}" style="text-transform: capitalize;">${name.replace(/_/g, ' ')}:</label>
        <div class="recipe-param-input-wrap">
          <input 
            type="text" 
            class="recipe-param-input" 
            id="param-input-${name}" 
            data-testid="param-input-${name}" 
            value="${p.value}" 
            title="Type exact number or formula (e.g. 120 / 2)" 
          />
          <span class="stat-value" id="param-val-${name}" style="display:none;">${p.value}</span>
        </div>
      `;

      const numInput = row.querySelector(`#param-input-${name}`) as HTMLInputElement;

      const slider = document.createElement('input');
      slider.type = 'range';
      slider.id = `param-slider-${name}`;
      slider.dataset.testid = `param-slider-${name}`;
      slider.min = p.min.toString();
      slider.max = p.max.toString();
      slider.step = p.step.toString();
      slider.value = p.value.toString();

      slider.addEventListener('input', (e) => {
        const val = parseFloat((e.target as HTMLInputElement).value);
        p.value = val;
        if (numInput) numInput.value = val.toString();
        const valEl = document.getElementById(`param-val-${name}`);
        if (valEl) valEl.textContent = val.toString();
        this.onParamChange(name, val);
      });

      numInput.addEventListener('change', () => {
        let val = parseFloat(numInput.value);
        if (isNaN(val)) {
          try {
            // Support simple arithmetic formulas like "100 / 2"
            val = Function(`'use strict'; return (${numInput.value})`)();
          } catch {}
        }
        if (!isNaN(val)) {
          if (val < p.min) p.min = Math.min(p.min, Math.floor(val));
          if (val > p.max) p.max = Math.max(p.max, Math.ceil(val * 1.5));
          if (val % 1 !== 0) p.step = 0.1;
          slider.min = p.min.toString();
          slider.max = p.max.toString();
          slider.step = p.step.toString();
          p.value = val;
          slider.value = val.toString();
          const valEl = document.getElementById(`param-val-${name}`);
          if (valEl) valEl.textContent = val.toString();
          this.onParamChange(name, val);
        }
      });

      group.appendChild(row);
      group.appendChild(slider);
      controlsContainer.appendChild(group);
    }

    this.container.appendChild(controlsContainer);

    // One-Click Download Actions
    const actionDivider = document.createElement('hr');
    actionDivider.style.border = 'none';
    actionDivider.style.borderTop = '1px solid rgba(255, 255, 255, 0.1)';
    actionDivider.style.margin = '12px 0 8px 0';
    this.container.appendChild(actionDivider);

    const actionsHeader = document.createElement('div');
    actionsHeader.style.fontSize = '11px';
    actionsHeader.style.color = '#8e99a8';
    actionsHeader.style.marginBottom = '6px';
    actionsHeader.textContent = 'EXPORT CAD ASSETS';
    this.container.appendChild(actionsHeader);

    const btnGroup = document.createElement('div');
    btnGroup.style.display = 'flex';
    btnGroup.style.flexDirection = 'column';
    btnGroup.style.gap = '6px';

    const btnStep = document.createElement('button');
    btnStep.className = 'btn-step';
    btnStep.dataset.testid = 'btn-maker-download-step';
    btnStep.innerHTML = '📥 Download STEP (.step)';
    btnStep.onclick = () => this.onDownloadStep?.();

    const btn3mf = document.createElement('button');
    btn3mf.className = 'btn-step';
    btn3mf.dataset.testid = 'btn-maker-download-3mf';
    btn3mf.innerHTML = '📦 Download 3MF (.3mf)';
    btn3mf.onclick = () => this.onDownload3mf?.();

    const btnDxf = document.createElement('button');
    btnDxf.className = 'btn-step';
    btnDxf.dataset.testid = 'btn-maker-download-dxf';
    btnDxf.innerHTML = '📐 Download DXF (.dxf)';
    btnDxf.onclick = () => this.onDownloadDxf?.();

    btnGroup.appendChild(btnStep);
    btnGroup.appendChild(btn3mf);
    btnGroup.appendChild(btnDxf);

    this.container.appendChild(btnGroup);
  }
}

/**
 * @file lil_controller.ts
 * 100% Official Three.js lil-gui Addon Controller for OpenCAD.
 * Powered by 'three/examples/jsm/libs/lil-gui.module.min.js'.
 * Provides high-precision floating parameter controls, dynamic probes,
 * and direct export actions driven by Code-CAD / CDML config.
 */

// @ts-ignore
import { GUI } from 'three/examples/jsm/libs/lil-gui.module.min.js';

export interface LilParamDef {
  value: number | boolean | string;
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
  label?: string;
  isPublic?: boolean;
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
  private gui: any = null;
  private params: Record<string, any> = {};
  private probeState: Record<string, any> = {};
  private paramControllers: Record<string, any> = {};

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

    if (this.config.gui !== false) {
      this.buildGui();
    }
  }

  private buildGui(): void {
    if (this.gui) {
      this.gui.destroy();
      this.gui = null;
    }

    this.paramControllers = {};
    this.probeState = {};

    // Instantiate official Three.js lil-gui addon
    this.gui = new GUI({
      container: this.container,
      title: this.config.title || 'OpenCAD Controller',
      autoPlace: false,
    });
    this.gui.open();

    // Ensure DOM test-ids and custom styles match OpenCAD specifications
    this.gui.domElement.setAttribute('data-testid', 'lil-controller');
    this.gui.domElement.classList.add('lil-controller');

    // 1. Parameters Folder (Public variables only!)
    const showSliders = this.config.sliders !== false;
    let paramEntries = Object.entries(this.config.params || {});

    // Filter public variables:
    // Exclude variables that start with '_' or have isPublic === false
    paramEntries = paramEntries.filter(([k, rawVal]) => {
      if (k.startsWith('_')) return false;
      if (typeof rawVal === 'object' && rawVal !== null && 'isPublic' in rawVal && (rawVal as any).isPublic === false) {
        return false;
      }
      return true;
    });

    if (this.config.vars && this.config.vars.length > 0) {
      const allowedVars = new Set(this.config.vars);
      paramEntries = paramEntries.filter(([k]) => allowedVars.has(k));
    }

    if (showSliders && paramEntries.length > 0) {
      const paramFolder = this.gui.addFolder('Parameters');
      paramFolder.open();
      paramFolder.domElement.setAttribute('data-testid', 'lil-folder-parameters');

      for (const [key, rawVal] of paramEntries) {
        const def: LilParamDef = typeof rawVal === 'object' && rawVal !== null && 'value' in rawVal
          ? rawVal as LilParamDef
          : { value: rawVal };

        const val = this.params[key] ?? def.value;
        this.params[key] = val;

        const min = def.min ?? (Number(val) < 0 ? Number(val) * 2 : 0);
        const max = def.max ?? (Number(val) > 100 ? Number(val) * 2 : (Number(val) === 0 ? 100 : Number(val) * 2));
        const step = def.step ?? (max - min <= 10 ? 0.1 : 1);

        const ctrl = paramFolder.add(this.params, key, min, max, step);
        ctrl.name(def.label || key);
        ctrl.domElement.setAttribute('data-testid', `lil-param-${key}`);

        // Annotate inputs for Playwright automated tests
        const numInput = ctrl.domElement.querySelector('input:not([type="range"])');
        if (numInput) {
          numInput.setAttribute('data-testid', `lil-param-input-${key}`);
        }
        const slider = ctrl.domElement.querySelector('input[type="range"]');
        if (slider) {
          slider.setAttribute('data-testid', `lil-param-slider-${key}`);
        }

        ctrl.onChange((newVal: any) => {
          this.params[key] = newVal;
          this.config.onParamChange?.(key, newVal);
        });

        this.paramControllers[key] = ctrl;
      }
    }

    // 2. Probes Live Monitors Folder
    const probeKeys = this.config.probes;
    if (probeKeys && probeKeys.length > 0) {
      const probeFolder = this.gui.addFolder('Probes & Quantities');
      probeFolder.open();
      probeFolder.domElement.setAttribute('data-testid', 'lil-folder-probes');

      for (const pid of probeKeys) {
        const rawVal = this.config.probeValues?.[pid];
        this.probeState[pid] = typeof rawVal === 'number' ? rawVal.toFixed(2) : (rawVal !== undefined ? String(rawVal) : '—');

        const pCtrl = probeFolder.add(this.probeState, pid).listen().disable();
        pCtrl.name(pid);
        pCtrl.domElement.setAttribute('data-testid', `lil-probe-${pid}`);

        const displayEl = pCtrl.domElement.querySelector('.widget, input') || pCtrl.domElement;
        displayEl.classList.add('lil-stat-value');
      }
    }

    // 3. Telemetry Folder (if specified)
    if (this.config.telemetry && Object.keys(this.config.telemetry).length > 0) {
      const telFolder = this.gui.addFolder('Telemetry');
      telFolder.open();
      telFolder.domElement.setAttribute('data-testid', 'lil-folder-telemetry');
      for (const tk of Object.keys(this.config.telemetry)) {
        const tCtrl = telFolder.add(this.config.telemetry, tk).listen().disable();
        tCtrl.name(tk);
      }
    }

    // 4. Actions & Exports Folder
    const hasExports = (this.config.exports && this.config.exports.length > 0) || (this.config.actions && this.config.actions.length > 0);
    if (hasExports) {
      const actionFolder = this.gui.addFolder('Exports');
      actionFolder.open();
      actionFolder.domElement.setAttribute('data-testid', 'lil-folder-actions');

      const reqExports = this.config.exports || this.config.actions || ['step', 'stl'];
      for (const exp of reqExports) {
        const cleanExp = exp.toLowerCase().replace(/^export/, '');
        const actionObj = {
          [cleanExp]: () => {
            this.config.onAction?.(cleanExp);
          },
        };

        const actCtrl = actionFolder.add(actionObj, cleanExp).name(`Export ${cleanExp.toUpperCase()}`);
        const btn = actCtrl.domElement.querySelector('button, .name') || actCtrl.domElement;
        btn.setAttribute('data-testid', `lil-action-${cleanExp}`);
        if (exp !== cleanExp) {
          btn.setAttribute('data-testid-full', `lil-action-${exp}`);
        }
      }
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

    this.buildGui();
  }

  public updateProbes(probes: Record<string, number | string>): void {
    this.config.probeValues = { ...(this.config.probeValues || {}), ...probes };
    for (const [k, v] of Object.entries(probes)) {
      const formatted = typeof v === 'number' ? v.toFixed(2) : String(v);
      this.probeState[k] = formatted;
      const el = this.gui?.domElement?.querySelector(`[data-testid="lil-probe-${k}"] .lil-stat-value, [data-testid="lil-probe-${k}"] input`) as HTMLInputElement | HTMLElement | null;
      if (el) {
        if ('value' in el) {
          (el as HTMLInputElement).value = formatted;
        } else {
          el.textContent = formatted;
        }
      }
    }
  }

  public updateTelemetry(telemetry: Record<string, string | number>): void {
    this.config.telemetry = { ...(this.config.telemetry || {}), ...telemetry };
    if (this.gui) {
      this.buildGui();
    }
  }

  public setParam(name: string, value: any): void {
    this.params[name] = value;
    if (this.paramControllers[name]) {
      this.paramControllers[name].setValue(value);
    }
  }

  public getParams(): Record<string, any> {
    return { ...this.params };
  }

  public getRootElement(): HTMLElement {
    return this.gui ? this.gui.domElement : this.container;
  }

  public show(): void {
    if (this.gui) this.gui.show();
  }

  public hide(): void {
    if (this.gui) this.gui.hide();
  }

  public destroy(): void {
    if (this.gui) {
      this.gui.destroy();
      this.gui = null;
    }
  }
}

import { PluginManager } from './PluginManager';

export interface TopRibbonOptions {
  container: HTMLElement;
  pluginManager: PluginManager;
  onEnterSketch?: () => void;
  onSelectPrimitive?: (type: string) => void;
  onApplyDressUp?: (op: 'fillet' | 'chamfer' | 'shell') => void;
  onImportStep?: () => void;
  onExportStep?: () => void;
  onSolveAssembly?: () => void;
  onBenchmarkAssembly?: () => void;
  onSelectLod?: (lod: string) => void;
}

export class TopRibbon {
  private container: HTMLElement;
  private pluginManager: PluginManager;
  private options: TopRibbonOptions;

  private tabButtons = new Map<string, HTMLButtonElement>();
  private actionContainer: HTMLElement;
  private currentWorkbench: string = 'design';

  constructor(options: TopRibbonOptions) {
    this.container = options.container;
    this.pluginManager = options.pluginManager;
    this.options = options;

    this.container.classList.add('opencad-top-ribbon');
    this.container.setAttribute('data-testid', 'ribbon-bar');

    // 1. Create Top Header Bar with Tabs
    const headerBar = document.createElement('div');
    headerBar.className = 'ribbon-header-bar';

    const brand = document.createElement('div');
    brand.className = 'ribbon-brand';
    brand.innerHTML = `
      <span class="ribbon-logo">📐</span>
      <span class="ribbon-title">OpenCAD</span>
      <span class="ribbon-pill">Shell v2.0</span>
    `;
    headerBar.appendChild(brand);

    const tabsContainer = document.createElement('div');
    tabsContainer.className = 'ribbon-tabs';

    const workbenches = [
      { id: 'design', label: '📐 Design', testId: 'tab-design' },
      { id: 'code-cad', label: '{ } Code-CAD', testId: 'tab-code-cad' },
      { id: 'git-cad', label: '🌿 Git-for-CAD', testId: 'tab-git-cad' },
      { id: 'sheetmetal', label: '📦 Sheet Metal', testId: 'tab-sheetmetal' },
      { id: 'fea-flexure', label: '⚡ FEA & Flexure', testId: 'tab-fea' },
      { id: 'implicit', label: '🌀 Implicit', testId: 'tab-implicit' },
      { id: 'cam-hlr', label: '⚙️ CAM / 3MF', testId: 'tab-cam' },
    ];

    for (const wb of workbenches) {
      const tabBtn = document.createElement('button');
      tabBtn.className = `ribbon-tab-btn ${wb.id === 'design' ? 'active' : ''}`;
      tabBtn.innerText = wb.label;
      tabBtn.setAttribute('data-testid', wb.testId);
      tabBtn.setAttribute('data-workbench', wb.id);
      tabBtn.addEventListener('click', () => {
        this.switchWorkbench(wb.id);
      });
      tabsContainer.appendChild(tabBtn);
      this.tabButtons.set(wb.id, tabBtn);
    }

    headerBar.appendChild(tabsContainer);

    // Right-side actions (FPS & View reset)
    const rightControls = document.createElement('div');
    rightControls.className = 'ribbon-right-controls';
    rightControls.innerHTML = `
      <span class="ribbon-status-badge" id="ribbon-fps-badge">60.0 FPS</span>
    `;
    headerBar.appendChild(rightControls);

    this.container.appendChild(headerBar);

    // 2. Create Context-Sensitive Action Ribbon
    this.actionContainer = document.createElement('div');
    this.actionContainer.className = 'ribbon-actions-bar';
    this.actionContainer.setAttribute('data-testid', 'ribbon-actions');
    this.container.appendChild(this.actionContainer);

    // Render default Design workbench actions
    this.renderDesignActions();

    // Listen to plugin manager workbench changes
    this.pluginManager.onWorkbenchChange((activeId) => {
      this.updateActiveTab(activeId || 'design');
    });
  }

  public getActionContainer(): HTMLElement {
    return this.actionContainer;
  }

  public async switchWorkbench(workbenchId: string): Promise<void> {
    if (this.currentWorkbench === workbenchId) return;

    this.currentWorkbench = workbenchId;
    this.updateActiveTab(workbenchId);

    if (workbenchId === 'design') {
      await this.pluginManager.deactivateCurrent();
      this.renderDesignActions();
    } else {
      try {
        await this.pluginManager.activate(workbenchId);
      } catch (err) {
        console.warn(`Failed to activate workbench ${workbenchId}:`, err);
        // Fallback for unconfigured workbenches
        this.actionContainer.innerHTML = `
          <div class="ribbon-action-group">
            <span class="ribbon-group-title">Status</span>
            <div class="ribbon-item-label">Workbench '${workbenchId}' loaded. Available in Wave 7.</div>
          </div>
        `;
      }
    }
  }

  private updateActiveTab(activeId: string): void {
    this.currentWorkbench = activeId;
    for (const [id, btn] of this.tabButtons.entries()) {
      if (id === activeId) {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    }
  }

  public renderDesignActions(): void {
    this.actionContainer.innerHTML = '';

    // Group 1: 2D Sketch
    const sketchGroup = this.createActionGroup('Sketch');
    const sketchBtn = this.createActionButton('✏️ New Sketch', 'ribbon-btn-sketch', () => {
      this.options.onEnterSketch?.();
      document.getElementById('btn-enter-sketch')?.click();
    });
    sketchBtn.setAttribute('data-testid', 'ribbon-btn-sketch');
    sketchGroup.appendChild(sketchBtn);
    this.actionContainer.appendChild(sketchGroup);

    // Group 2: Solid Primitives
    const primGroup = this.createActionGroup('Primitives');
    const boxBtn = this.createActionButton('🧊 Box', 'ribbon-btn-box', () => {
      const select = document.getElementById('primitive-select') as HTMLSelectElement | null;
      if (select) {
        select.value = 'box';
        select.dispatchEvent(new Event('change'));
      }
      this.options.onSelectPrimitive?.('box');
    });
    const cylBtn = this.createActionButton('🔘 Cylinder', 'ribbon-btn-cyl', () => {
      const select = document.getElementById('primitive-select') as HTMLSelectElement | null;
      if (select) {
        select.value = 'cylinder';
        select.dispatchEvent(new Event('change'));
      }
      this.options.onSelectPrimitive?.('cylinder');
    });
    const dagBtn = this.createActionButton('🌳 DAG Solid', 'ribbon-btn-dag', () => {
      const select = document.getElementById('primitive-select') as HTMLSelectElement | null;
      if (select) {
        select.value = 'dag';
        select.dispatchEvent(new Event('change'));
      }
      this.options.onSelectPrimitive?.('dag');
    });
    primGroup.appendChild(boxBtn);
    primGroup.appendChild(cylBtn);
    primGroup.appendChild(dagBtn);
    this.actionContainer.appendChild(primGroup);

    // Group 3: Dress-Up
    const dressGroup = this.createActionGroup('Dress-Up');
    const filletBtn = this.createActionButton('🪚 Fillet', 'ribbon-btn-fillet', () => {
      this.options.onApplyDressUp?.('fillet');
      document.getElementById('btn-fillet')?.click();
    });
    const chamferBtn = this.createActionButton('📐 Chamfer', 'ribbon-btn-chamfer', () => {
      this.options.onApplyDressUp?.('chamfer');
      document.getElementById('btn-chamfer')?.click();
    });
    const shellBtn = this.createActionButton('🥣 Shell', 'ribbon-btn-shell', () => {
      this.options.onApplyDressUp?.('shell');
      document.getElementById('btn-shell')?.click();
    });
    dressGroup.appendChild(filletBtn);
    dressGroup.appendChild(chamferBtn);
    dressGroup.appendChild(shellBtn);
    this.actionContainer.appendChild(dressGroup);

    // Group 4: STEP I/O
    const stepGroup = this.createActionGroup('STEP B-Rep');
    const importBtn = this.createActionButton('📥 Import', 'ribbon-btn-import-step', () => {
      this.options.onImportStep?.();
      document.getElementById('btn-import-step')?.click();
    });
    const exportBtn = this.createActionButton('📤 Export', 'ribbon-btn-export-step', () => {
      this.options.onExportStep?.();
      document.getElementById('btn-export-step')?.click();
    });
    stepGroup.appendChild(importBtn);
    stepGroup.appendChild(exportBtn);
    this.actionContainer.appendChild(stepGroup);

    // Group 5: Assembly Mates
    const assemblyGroup = this.createActionGroup('Assembly');
    const addPartBtn = this.createActionButton('➕ Part', 'ribbon-btn-part', () => {
      document.getElementById('btn-insert-part')?.click();
    });
    const solveBtn = this.createActionButton('⚡ Solve Mates', 'ribbon-btn-solve', () => {
      this.options.onSolveAssembly?.();
      document.getElementById('btn-solve-assembly')?.click();
    });
    const benchBtn = this.createActionButton('🚀 500 Bench', 'ribbon-btn-bench', () => {
      this.options.onBenchmarkAssembly?.();
      document.getElementById('btn-benchmark-assembly')?.click();
    });
    assemblyGroup.appendChild(addPartBtn);
    assemblyGroup.appendChild(solveBtn);
    assemblyGroup.appendChild(benchBtn);
    this.actionContainer.appendChild(assemblyGroup);
  }

  private createActionGroup(title: string): HTMLElement {
    const group = document.createElement('div');
    group.className = 'ribbon-action-group';
    const label = document.createElement('div');
    label.className = 'ribbon-group-title';
    label.innerText = title;
    group.appendChild(label);
    return group;
  }

  private createActionButton(text: string, className: string, onClick: () => void): HTMLButtonElement {
    const btn = document.createElement('button');
    btn.className = `ribbon-action-btn ${className}`;
    btn.setAttribute('data-testid', className);
    btn.innerText = text;
    btn.addEventListener('click', onClick);
    return btn;
  }
}

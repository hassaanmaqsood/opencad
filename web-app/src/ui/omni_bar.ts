/**
 * @file omni_bar.ts
 * Wave 14: Top-Center Universal Omni-Bar (Cmd+K / / / S shortcut).
 * Accepts CAD tool searches, mathematical parameter assignments,
 * slash commands, and natural-language/AI prompts in one unified bar.
 */

export interface OmniCommand {
  id: string;
  name: string;
  category: 'tool' | 'slash' | 'param' | 'ai';
  description: string;
  shortcut?: string;
  icon: string;
  action: (arg?: string) => Promise<void> | void;
}

export interface OmniBarOptions {
  container?: HTMLElement;
  onExecuteCommand: (cmdId: string, arg?: string) => Promise<void> | void;
  onSetParameter: (paramName: string, value: number) => void;
  onAiPrompt: (prompt: string) => Promise<void> | void;
}

export class UniversalOmniBar {
  private container: HTMLElement;
  private inputEl: HTMLInputElement;
  private dropdownEl: HTMLElement;
  private options: OmniBarOptions;
  private commands: OmniCommand[] = [];
  private isOpen: boolean = false;
  private selectedIndex: number = 0;

  constructor(options: OmniBarOptions) {
    this.options = options;

    this.container = options.container || document.createElement('div');
    this.container.className = 'omni-bar-container';
    this.container.id = 'omni-bar-container';
    this.container.setAttribute('data-testid', 'omni-bar');

    this.container.innerHTML = `
      <div class="omni-bar-shell">
        <span class="omni-bar-search-icon">🔍</span>
        <input 
          type="text" 
          id="omni-bar-input" 
          class="omni-bar-input" 
          data-testid="omni-bar-input" 
          placeholder="Search tools, type math (length = 120), run /commands, or prompt AI... (Cmd+K / S)" 
          autocomplete="off" 
          spellcheck="false" 
        />
        <span class="omni-shortcut-badge" title="Press Cmd+K, /, or S to focus"><kbd>⌘K</kbd></span>
      </div>
      <div id="omni-dropdown" class="omni-dropdown hud-panel" data-testid="omni-dropdown" style="display: none;"></div>
    `;

    this.inputEl = this.container.querySelector('#omni-bar-input')!;
    this.dropdownEl = this.container.querySelector('#omni-dropdown')!;

    this.initDefaultCommands();
    this.setupListeners();
  }

  public getElement(): HTMLElement {
    return this.container;
  }

  public isDropdownOpen(): boolean {
    return this.isOpen;
  }

  private initDefaultCommands(): void {
    this.commands = [
      // CAD Operations & Tools
      { id: 'extrude', name: 'Extrude', category: 'tool', description: 'Extrude 2D sketch or face add/cut', icon: '📦', shortcut: 'E', action: () => this.options.onExecuteCommand('extrude') },
      { id: 'revolve', name: 'Revolve', category: 'tool', description: 'Revolve profile about axis', icon: '🔘', shortcut: 'R', action: () => this.options.onExecuteCommand('revolve') },
      { id: 'fillet', name: 'Fillet', category: 'tool', description: 'Constant-radius edge rounding', icon: '🪚', shortcut: 'F', action: () => this.options.onExecuteCommand('fillet') },
      { id: 'chamfer', name: 'Chamfer', category: 'tool', description: 'Equal/angle edge bevel', icon: '📐', shortcut: 'C', action: () => this.options.onExecuteCommand('chamfer') },
      { id: 'hole_wizard', name: 'Hole Wizard', category: 'tool', description: 'Counterbore, countersink, tapped holes', icon: '🕳️', shortcut: 'H', action: () => this.options.onExecuteCommand('hole_wizard') },
      { id: 'thread', name: 'Thread', category: 'tool', description: 'Cosmetic or modeled helical screw thread', icon: '🔩', shortcut: 'T', action: () => this.options.onExecuteCommand('thread') },
      { id: 'flange', name: 'Sheet Metal Flange', category: 'tool', description: 'Add 90° sheet metal flange with K-factor', icon: '📦', action: () => this.options.onExecuteCommand('flange') },
      { id: 'gyroid', name: 'Gyroid TPMS Infill', category: 'tool', description: 'Minimal surface lattice modulation', icon: '🌀', action: () => this.options.onExecuteCommand('gyroid') },
      { id: 'mate', name: 'Assembly Mate', category: 'tool', description: 'Add kinematic joint mate', icon: '🔗', shortcut: 'M', action: () => this.options.onExecuteCommand('mate') },
      { id: 'datum_plane', name: 'Datum Plane', category: 'tool', description: 'Offset, angled, or 3-point construction datum', icon: '📍', action: () => this.options.onExecuteCommand('datum_plane') },
      { id: 'split_body', name: 'Split Body', category: 'tool', description: 'Cut body with plane or surface tool', icon: '✂️', action: () => this.options.onExecuteCommand('split_body') },
      { id: 'sketch', name: 'New 2D Sketch', category: 'tool', description: 'Enter planar sketch mode', icon: '✏️', shortcut: 'K', action: () => this.options.onExecuteCommand('sketch') },

      // Slash Commands
      { id: 'slash_step', name: '/export step', category: 'slash', description: 'Export ISO-10303-21 STEP AP214 B-Rep solid', icon: '📥', action: () => this.options.onExecuteCommand('export_step') },
      { id: 'slash_3mf', name: '/export 3mf', category: 'slash', description: 'Export 3MF production package with lattice', icon: '📦', action: () => this.options.onExecuteCommand('export_3mf') },
      { id: 'slash_dxf', name: '/export dxf', category: 'slash', description: 'Export 2D technical drawing as DXF', icon: '📐', action: () => this.options.onExecuteCommand('export_dxf') },
      { id: 'slash_diff', name: '/git diff', category: 'slash', description: 'Open visual side-by-side Git diff panel', icon: '🌿', action: () => this.options.onExecuteCommand('git_diff') },
      { id: 'slash_screenshot', name: '/screenshot', category: 'slash', description: 'Capture 4-angle orthographic image snapshots', icon: '📸', action: () => this.options.onExecuteCommand('screenshot') },
      { id: 'slash_zebra', name: '/inspect zebra', category: 'slash', description: 'Toggle zebra stripe curvature continuity shader', icon: '🦓', action: () => this.options.onExecuteCommand('inspect_zebra') },
    ];
  }

  private setupListeners(): void {
    // Global hotkeys: Cmd+K / Ctrl+K, /, or S (when not in an input)
    window.addEventListener('keydown', (e: KeyboardEvent) => {
      const activeEl = document.activeElement as HTMLElement | null;
      const isInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA' || activeEl.isContentEditable);

      if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        this.focus();
      } else if (!isInput && e.key === '/') {
        e.preventDefault();
        this.inputEl.value = '/';
        this.focus();
        this.updateDropdown();
      } else if (!isInput && (e.key === 's' || e.key === 'S')) {
        // If target is not the 3D canvas (where Radial Menu binds 'S'), focus omni-bar
        const isCanvas = activeEl && (activeEl.id === 'cad-canvas' || activeEl.tagName === 'CANVAS');
        if (!isCanvas && !e.altKey && !e.metaKey && !e.ctrlKey) {
          e.preventDefault();
          this.focus();
        }
      } else if (e.key === 'Escape') {
        this.closeDropdown();
        this.inputEl.blur();
      }
    });

    this.inputEl.addEventListener('focus', () => {
      this.updateDropdown();
    });

    this.inputEl.addEventListener('input', () => {
      this.updateDropdown();
    });

    this.inputEl.addEventListener('keydown', (e: KeyboardEvent) => {
      const items = this.getFilteredCommands();
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        this.selectedIndex = (this.selectedIndex + 1) % Math.max(1, items.length);
        this.highlightSelected();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        this.selectedIndex = (this.selectedIndex - 1 + items.length) % Math.max(1, items.length);
        this.highlightSelected();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        this.executeCurrentInput();
      }
    });

    document.addEventListener('click', (e: MouseEvent) => {
      if (!this.container.contains(e.target as Node)) {
        this.closeDropdown();
      }
    });
  }

  public focus(): void {
    this.inputEl.focus();
    this.inputEl.select();
    this.updateDropdown();
  }

  private getFilteredCommands(): OmniCommand[] {
    const raw = this.inputEl.value.trim().toLowerCase();
    if (!raw) return this.commands.slice(0, 8);

    // If typing math assignment (e.g. `length = 120`)
    if (raw.includes('=')) {
      return [];
    }

    return this.commands.filter((cmd) => {
      return (
        cmd.name.toLowerCase().includes(raw) ||
        cmd.description.toLowerCase().includes(raw) ||
        cmd.id.includes(raw)
      );
    });
  }

  private updateDropdown(): void {
    const text = this.inputEl.value.trim();
    const filtered = this.getFilteredCommands();

    this.dropdownEl.innerHTML = '';
    this.selectedIndex = 0;

    // Check if user is typing math assignment
    const paramMatch = text.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)$/);
    if (paramMatch) {
      const paramName = paramMatch[1];
      const val = parseFloat(paramMatch[2]);
      const paramRow = document.createElement('div');
      paramRow.className = 'omni-dropdown-item active';
      paramRow.setAttribute('data-testid', 'omni-item-param');
      paramRow.innerHTML = `
        <span class="omni-item-icon">⚙️</span>
        <div class="omni-item-content">
          <span class="omni-item-title">Set Parameter: <b>${paramName}</b> = ${val}</span>
          <span class="omni-item-desc">Press Enter to update living recipe & recalculate model</span>
        </div>
      `;
      paramRow.addEventListener('click', () => {
        this.options.onSetParameter(paramName, val);
        this.closeDropdown();
        this.inputEl.value = '';
      });
      this.dropdownEl.appendChild(paramRow);
      this.dropdownEl.style.display = 'block';
      this.isOpen = true;
      return;
    }

    if (filtered.length === 0 && text.length > 2) {
      // Natural Language AI Prompt suggestion
      const aiRow = document.createElement('div');
      aiRow.className = 'omni-dropdown-item active';
      aiRow.setAttribute('data-testid', 'omni-item-ai');
      aiRow.innerHTML = `
        <span class="omni-item-icon">🤖</span>
        <div class="omni-item-content">
          <span class="omni-item-title">Prompt AI Agent: "${text}"</span>
          <span class="omni-item-desc">Press Enter to execute autonomous CAD command</span>
        </div>
      `;
      aiRow.addEventListener('click', () => {
        this.options.onAiPrompt(text);
        this.closeDropdown();
        this.inputEl.value = '';
      });
      this.dropdownEl.appendChild(aiRow);
      this.dropdownEl.style.display = 'block';
      this.isOpen = true;
      return;
    }

    if (filtered.length === 0) {
      this.closeDropdown();
      return;
    }

    for (let i = 0; i < filtered.length; i++) {
      const cmd = filtered[i];
      const row = document.createElement('div');
      row.className = `omni-dropdown-item ${i === this.selectedIndex ? 'active' : ''}`;
      row.setAttribute('data-testid', `omni-item-${cmd.id}`);
      row.innerHTML = `
        <span class="omni-item-icon">${cmd.icon}</span>
        <div class="omni-item-content">
          <div class="omni-item-title-row">
            <span class="omni-item-title">${cmd.name}</span>
            ${cmd.shortcut ? `<span class="omni-item-shortcut">${cmd.shortcut}</span>` : ''}
          </div>
          <span class="omni-item-desc">${cmd.description}</span>
        </div>
      `;
      row.addEventListener('click', () => {
        this.closeDropdown();
        this.inputEl.value = '';
        cmd.action();
      });
      this.dropdownEl.appendChild(row);
    }

    this.dropdownEl.style.display = 'block';
    this.isOpen = true;
  }

  private highlightSelected(): void {
    const children = Array.from(this.dropdownEl.children);
    children.forEach((el, idx) => {
      el.classList.toggle('active', idx === this.selectedIndex);
    });
  }

  private executeCurrentInput(): void {
    const text = this.inputEl.value.trim();

    // 1. Parameter Assignment
    const paramMatch = text.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)$/);
    if (paramMatch) {
      const paramName = paramMatch[1];
      const val = parseFloat(paramMatch[2]);
      this.options.onSetParameter(paramName, val);
      this.closeDropdown();
      this.inputEl.value = '';
      return;
    }

    // 2. Filtered commands match
    const filtered = this.getFilteredCommands();
    if (filtered.length > 0 && this.selectedIndex < filtered.length) {
      const cmd = filtered[this.selectedIndex];
      this.closeDropdown();
      this.inputEl.value = '';
      cmd.action();
      return;
    }

    // 3. Fallback to AI prompt
    if (text) {
      this.options.onAiPrompt(text);
      this.closeDropdown();
      this.inputEl.value = '';
    }
  }

  public closeDropdown(): void {
    this.dropdownEl.style.display = 'none';
    this.isOpen = false;
  }
}

/**
 * @file living_recipe_dock.ts
 * Wave 14: Left "Living Recipe" Dock.
 * Merges Parameter Sliders + Feature & Assembly DAG Tree + Code-CAD Split Pane
 * into a single unified living recipe panel.
 */

export interface LivingRecipeDockOptions {
  onToggleCodeCad?: () => void;
  onToggleGitCad?: () => void;
}

export class LivingRecipeDock {
  private container: HTMLElement;
  private options: LivingRecipeDockOptions;
  private isCodeOpen: boolean = false;

  constructor(options: LivingRecipeDockOptions = {}) {
    this.options = options;

    let el = document.getElementById('living-recipe-dock');
    if (!el) {
      el = document.createElement('div');
      el.id = 'living-recipe-dock';
      const appContainer = document.getElementById('app-container') || document.body;
      appContainer.appendChild(el);
    }
    this.container = el;
    this.container.className = 'living-recipe-dock hud-panel';
    this.container.setAttribute('data-testid', 'living-recipe-dock');

    this.render();
    this.setupListeners();
  }

  public getElement(): HTMLElement {
    return this.container;
  }

  private render(): void {
    this.container.innerHTML = `
      <div class="recipe-dock-header">
        <div class="recipe-dock-title">
          <span class="recipe-icon">📋</span>
          <span class="recipe-title-text">Living Recipe</span>
        </div>
        <div class="recipe-dock-actions">
          <button id="recipe-btn-code" class="recipe-action-btn" data-testid="recipe-btn-code" title="Toggle synchronized .ocad.ts code (Ctrl+\`)">
            { } Code
          </button>
          <button id="recipe-btn-git" class="recipe-action-btn" data-testid="recipe-btn-git" title="Toggle Git-for-CAD visual diff">
            🌿 Git
          </button>
        </div>
      </div>

      <!-- Top Section: Parameter Sliders -->
      <div id="recipe-parameter-sliders" class="recipe-parameter-sliders" data-testid="recipe-parameter-sliders"></div>

      <!-- Main Section: Feature & Assembly DAG Tree -->
      <div id="recipe-dag-container" class="recipe-dag-container"></div>
    `;

    // Move existing feature-tree-panel inside recipe-dag-container
    const existingTree = document.getElementById('feature-tree-panel');
    const dagContainer = this.container.querySelector('#recipe-dag-container');
    if (existingTree && dagContainer) {
      dagContainer.appendChild(existingTree);
    }

    // Move existing parameter-sliders-panel inside recipe-parameter-sliders
    const existingSliders = document.getElementById('parameter-sliders-panel');
    const slidersContainer = this.container.querySelector('#recipe-parameter-sliders');
    if (existingSliders && slidersContainer) {
      slidersContainer.appendChild(existingSliders);
    }
  }

  private setupListeners(): void {
    const codeBtn = this.container.querySelector('#recipe-btn-code');
    const gitBtn = this.container.querySelector('#recipe-btn-git');

    codeBtn?.addEventListener('click', () => {
      this.isCodeOpen = !this.isCodeOpen;
      codeBtn.classList.toggle('active', this.isCodeOpen);
      this.options.onToggleCodeCad?.();
    });

    gitBtn?.addEventListener('click', () => {
      gitBtn.classList.toggle('active');
      this.options.onToggleGitCad?.();
    });

    // Hotkey: Ctrl+` to toggle Code-CAD editor
    window.addEventListener('keydown', (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && (e.key === '`' || e.key === '~')) {
        e.preventDefault();
        this.isCodeOpen = !this.isCodeOpen;
        codeBtn?.classList.toggle('active', this.isCodeOpen);
        this.options.onToggleCodeCad?.();
      }
    });
  }
}

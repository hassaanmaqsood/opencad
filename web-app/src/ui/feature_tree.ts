import {
  CadFeatureNode,
  CadFeatureType,
} from '../types/cad';

export interface FeatureTreeOptions {
  container: HTMLElement;
  initialNodes: CadFeatureNode[];
  initialRollbackIndex?: number;
  onRollbackChange: (rollbackIndex: number) => void;
  onSuppressionToggle: (featureId: number, suppressed: boolean) => void;
}

export class FeatureTree {
  private container: HTMLElement;
  private nodes: CadFeatureNode[];
  private rollbackIndex: number;
  private onRollbackChange: (rollbackIndex: number) => void;
  private onSuppressionToggle: (featureId: number, suppressed: boolean) => void;

  private isDraggingRollback: boolean = false;
  private featureListEl!: HTMLElement;
  private activeCountEl!: HTMLElement;

  constructor(options: FeatureTreeOptions) {
    this.container = options.container;
    this.nodes = [...options.initialNodes];
    this.rollbackIndex =
      options.initialRollbackIndex !== undefined
        ? options.initialRollbackIndex
        : this.nodes.length - 1;
    this.onRollbackChange = options.onRollbackChange;
    this.onSuppressionToggle = options.onSuppressionToggle;

    this.render();
  }

  private getFeatureIcon(type: CadFeatureType): string {
    switch (type) {
      case CadFeatureType.SKETCH:
        return '✏️';
      case CadFeatureType.EXTRUDE:
        return '📦';
      case CadFeatureType.REVOLVE:
        return '🔄';
      case CadFeatureType.BOOLEAN_UNION:
        return '∪';
      case CadFeatureType.BOOLEAN_CUT:
        return '⊖';
      case CadFeatureType.BOOLEAN_INTERSECT:
        return '∩';
      case CadFeatureType.FILLET:
        return '⌒';
      case CadFeatureType.CHAMFER:
        return '📐';
      default:
        return '⚙️';
    }
  }

  public render(): void {
    this.container.innerHTML = `
      <div class="tree-header">
        <div class="tree-header-title">
          <span class="tree-icon">🌲</span> Feature Manager
        </div>
        <span class="tree-badge" id="tree-active-count" data-testid="tree-active-count">0 Active</span>
      </div>
      <div class="tree-subtitle">Parametric History DAG</div>
      <div id="feature-list" class="feature-list" data-testid="feature-list"></div>
      <div class="tree-footer">
        <button id="btn-reset-dag" class="btn-tree-action" data-testid="btn-reset-dag">↺ Reset Demo DAG</button>
      </div>
    `;

    this.featureListEl = this.container.querySelector('#feature-list') as HTMLElement;
    this.activeCountEl = this.container.querySelector('#tree-active-count') as HTMLElement;

    const btnReset = this.container.querySelector('#btn-reset-dag');
    if (btnReset) {
      btnReset.addEventListener('click', () => {
        this.rollbackIndex = this.nodes.length - 1;
        for (const n of this.nodes) {
          n.is_suppressed = false;
        }
        this.renderFeatureItems();
        this.onRollbackChange(this.rollbackIndex);
      });
    }

    this.renderFeatureItems();
    this.setupRollbackDragListeners();
  }

  public renderFeatureItems(): void {
    if (!this.featureListEl) return;
    this.featureListEl.innerHTML = '';

    let activeCount = 0;

    for (let i = 0; i < this.nodes.length; i++) {
      const node = this.nodes[i];
      const isRolledBack = i > this.rollbackIndex;
      const isSuppressed = node.is_suppressed;

      if (!isRolledBack && !isSuppressed) {
        activeCount++;
      }

      // Feature Item Row
      const itemEl = document.createElement('div');
      itemEl.className = `feature-item ${isRolledBack ? 'rolled-back' : ''} ${
        isSuppressed ? 'suppressed' : ''
      }`;
      itemEl.dataset.index = i.toString();
      itemEl.dataset.featureId = node.feature_id.toString();
      itemEl.setAttribute('data-testid', `feature-item-${node.feature_id}`);

      const iconSpan = document.createElement('span');
      iconSpan.className = 'feature-type-icon';
      iconSpan.textContent = this.getFeatureIcon(node.type);

      const nameSpan = document.createElement('span');
      nameSpan.className = 'feature-name';
      nameSpan.textContent = node.name;
      nameSpan.title = `${node.name} (ID: ${node.feature_id})`;

      itemEl.appendChild(iconSpan);
      itemEl.appendChild(nameSpan);

      // Status badges
      if (isRolledBack) {
        const rbBadge = document.createElement('span');
        rbBadge.className = 'status-badge rolled-back-badge';
        rbBadge.textContent = 'Rolled Back';
        itemEl.appendChild(rbBadge);
      } else if (isSuppressed) {
        const supBadge = document.createElement('span');
        supBadge.className = 'status-badge suppressed-badge';
        supBadge.textContent = 'Suppressed';
        itemEl.appendChild(supBadge);
      }

      // Suppression Toggle Button
      const btnSuppress = document.createElement('button');
      btnSuppress.className = 'btn-suppress';
      btnSuppress.setAttribute('data-testid', `btn-suppress-${node.feature_id}`);
      btnSuppress.title = node.is_suppressed ? 'Unsuppress feature' : 'Suppress feature';
      btnSuppress.innerHTML = node.is_suppressed ? '🚫' : '👁️';

      btnSuppress.addEventListener('click', (e) => {
        e.stopPropagation();
        node.is_suppressed = !node.is_suppressed;
        this.renderFeatureItems();
        this.onSuppressionToggle(node.feature_id, node.is_suppressed);
      });

      itemEl.appendChild(btnSuppress);

      // Clicking row jumps rollback bar to this feature
      itemEl.addEventListener('click', () => {
        this.setRollbackIndex(i);
      });

      this.featureListEl.appendChild(itemEl);

      // If this feature matches active rollbackIndex, insert the Draggable Rollback Bar directly below it
      if (i === this.rollbackIndex) {
        this.featureListEl.appendChild(this.createRollbackBarElement());
      }
    }

    // If rollbackIndex < 0 (all rolled back), put bar at the very top
    if (this.rollbackIndex < 0) {
      this.featureListEl.insertBefore(
        this.createRollbackBarElement(),
        this.featureListEl.firstChild
      );
    }

    if (this.activeCountEl) {
      this.activeCountEl.textContent = `${activeCount} / ${this.nodes.length} Active`;
    }
  }

  private createRollbackBarElement(): HTMLElement {
    const barEl = document.createElement('div');
    barEl.className = 'rollback-bar-container';
    barEl.id = 'rollback-bar';
    barEl.setAttribute('data-testid', 'rollback-bar');

    barEl.innerHTML = `
      <div class="rollback-line"></div>
      <div class="rollback-handle" data-testid="rollback-handle" title="Drag up/down to roll back modeling history">
        <span class="rollback-grip">⫪</span>
        <span class="rollback-text">Rollback Bar</span>
      </div>
      <div class="rollback-line"></div>
    `;

    return barEl;
  }

  private setupRollbackDragListeners(): void {
    const onPointerMove = (e: PointerEvent) => {
      if (!this.isDraggingRollback) return;
      e.preventDefault();

      const items = Array.from(
        this.featureListEl.querySelectorAll('.feature-item')
      ) as HTMLElement[];
      if (items.length === 0) return;

      const pointerY = e.clientY;
      let targetIndex = 0;

      // Find closest feature row boundary
      for (let i = 0; i < items.length; i++) {
        const rect = items[i].getBoundingClientRect();
        const midY = rect.top + rect.height / 2;
        if (pointerY >= midY) {
          targetIndex = i;
        }
      }

      if (pointerY < items[0].getBoundingClientRect().top) {
        targetIndex = 0;
      }

      if (targetIndex !== this.rollbackIndex) {
        this.rollbackIndex = targetIndex;
        this.renderFeatureItems();
      }
    };

    const onPointerUp = () => {
      if (!this.isDraggingRollback) return;
      this.isDraggingRollback = false;
      window.removeEventListener('pointermove', onPointerMove);
      window.removeEventListener('pointerup', onPointerUp);
      document.body.classList.remove('dragging-rollback');

      this.onRollbackChange(this.rollbackIndex);
    };

    this.container.addEventListener('pointerdown', (e) => {
      const target = e.target as HTMLElement;
      if (
        target.closest('.rollback-handle') ||
        target.closest('.rollback-bar-container')
      ) {
        e.preventDefault();
        this.isDraggingRollback = true;
        document.body.classList.add('dragging-rollback');
        window.addEventListener('pointermove', onPointerMove);
        window.addEventListener('pointerup', onPointerUp);
      }
    });
  }

  public setRollbackIndex(index: number): void {
    const clamped = Math.max(0, Math.min(index, this.nodes.length - 1));
    if (this.rollbackIndex !== clamped) {
      this.rollbackIndex = clamped;
      this.renderFeatureItems();
      this.onRollbackChange(this.rollbackIndex);
    }
  }

  public getRollbackIndex(): number {
    return this.rollbackIndex;
  }

  public getNodes(): CadFeatureNode[] {
    return this.nodes;
  }

  public setNodes(nodes: CadFeatureNode[]): void {
    this.nodes = [...nodes];
    this.rollbackIndex = Math.min(this.rollbackIndex, this.nodes.length - 1);
    this.renderFeatureItems();
  }

  public toggleSuppression(featureId: number): void {
    const node = this.nodes.find((n) => n.feature_id === featureId);
    if (node) {
      node.is_suppressed = !node.is_suppressed;
      this.renderFeatureItems();
      this.onSuppressionToggle(featureId, node.is_suppressed);
    }
  }
}

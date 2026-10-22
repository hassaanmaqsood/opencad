import { OpenCadExtensionPlugin, PluginContext, VisualDiffData } from '../../core-shell/PluginTypes';
import { CadFeatureType, CadFeatureNode } from '../../types/cad';

export interface CadCommit {
  id: string;
  shortHash: string;
  message: string;
  author: string;
  timestamp: string;
  dagSnapshot: CadFeatureNode[];
}

export class GitCadPlugin implements OpenCadExtensionPlugin {
  public metadata = {
    id: 'git-cad',
    name: 'Git-for-CAD',
    version: '1.0.0',
    icon: '🌿',
    category: 'versioning' as const,
    description: 'Semantic Git version control with 3D Boolean visual diff and 3-way AST merge resolution',
    wasmUrl: '/cad_ast.wasm',
  };

  private context: PluginContext | null = null;
  private commits: CadCommit[] = [];
  private selectedCommitId: string | null = null;
  private isDiffActive: boolean = false;

  private commitListContainer: HTMLElement | null = null;
  private diffSummaryBadge: HTMLElement | null = null;
  private conflictCountBadge: HTMLElement | null = null;

  constructor() {
    this.initDefaultCommits();
  }

  private initDefaultCommits(): void {
    const baseBox: CadFeatureNode[] = [
      {
        feature_id: 1,
        name: 'Base Box',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [],
        params: { extrude: { distance: 2.0 } },
      },
    ];

    const withFillet: CadFeatureNode[] = [
      ...baseBox,
      {
        feature_id: 2,
        name: 'Fillet 1',
        type: CadFeatureType.FILLET,
        is_suppressed: false,
        parent_ids: [1],
        params: { fillet: { radius: 0.25 } },
      },
    ];

    this.commits = [
      {
        id: 'c1-init',
        shortHash: 'a1b2c3d',
        message: 'Initial CAD part geometry (Base Box)',
        author: 'cad-engineer',
        timestamp: '10 mins ago',
        dagSnapshot: baseBox,
      },
      {
        id: 'c2-fillet',
        shortHash: 'e4f5a6b',
        message: 'Add 0.25mm edge blend fillets',
        author: 'cad-engineer',
        timestamp: '3 mins ago',
        dagSnapshot: withFillet,
      },
    ];
    this.selectedCommitId = 'c1-init';
  }

  public async initialize(context: PluginContext): Promise<void> {
    this.context = context;

    try {
      const resp = await fetch('/cad_ast.wasm');
      if (resp.ok) {
        const bin = await resp.arrayBuffer();
        await context.bridge.loadPluginWasm('ast', bin);
      }
    } catch (e) {
      console.warn('Failed to pre-fetch /cad_ast.wasm for Git-CAD plugin:', e);
    }
  }

  public async activate(): Promise<void> {
    this.isDiffActive = false;
  }

  public async deactivate(): Promise<void> {
    if (this.context) {
      this.context.setVisualDiff(null);
    }
    this.isDiffActive = false;
  }

  public renderRibbonActions(container: HTMLElement): void {
    container.innerHTML = '';

    const group = document.createElement('div');
    group.className = 'ribbon-action-group';

    const title = document.createElement('div');
    title.className = 'ribbon-group-title';
    title.innerText = 'Git Versioning';
    group.appendChild(title);

    const diffBtn = document.createElement('button');
    diffBtn.className = 'ribbon-action-btn ribbon-btn-diff';
    diffBtn.innerText = this.isDiffActive ? '👁️ Hide 3D Diff' : '👁️ 3D Visual Diff';
    diffBtn.setAttribute('data-testid', 'btn-git-diff');
    diffBtn.addEventListener('click', () => this.toggleVisualDiff());
    group.appendChild(diffBtn);

    const commitBtn = document.createElement('button');
    commitBtn.className = 'ribbon-action-btn ribbon-btn-commit';
    commitBtn.innerText = '💾 Commit DAG';
    commitBtn.setAttribute('data-testid', 'btn-git-commit-ribbon');
    commitBtn.addEventListener('click', () => this.promptCommit());
    group.appendChild(commitBtn);

    const mergeBtn = document.createElement('button');
    mergeBtn.className = 'ribbon-action-btn ribbon-btn-merge';
    mergeBtn.innerText = '🔀 3-Way AST Merge';
    mergeBtn.setAttribute('data-testid', 'btn-git-merge');
    mergeBtn.addEventListener('click', () => this.perform3WayMerge());
    group.appendChild(mergeBtn);

    container.appendChild(group);
  }

  public renderSidePanel(container: HTMLElement): void {
    container.innerHTML = '';
    container.className = 'plugin-side-panel git-cad-side-panel';
    container.setAttribute('data-testid', 'git-cad-panel');

    // Header with branch selector
    const header = document.createElement('div');
    header.className = 'side-panel-header';
    header.innerHTML = `
      <div class="side-panel-title">
        <span>🌿</span> Git-for-CAD
      </div>
      <div class="git-branch-selector">
        <label for="git-branch-select">Branch:</label>
        <select id="git-branch-select" data-testid="git-branch-select">
          <option value="main" selected>main</option>
          <option value="feature/fillet">feature/fillet</option>
          <option value="feature/shell">feature/shell</option>
        </select>
      </div>
    `;
    container.appendChild(header);

    // Commit Action Box
    const commitBox = document.createElement('div');
    commitBox.className = 'git-commit-box';
    commitBox.innerHTML = `
      <input type="text" id="git-commit-input" class="git-commit-input" data-testid="git-commit-input" placeholder="Commit message (e.g. Added mounting holes)" />
      <button id="btn-git-commit" class="btn-git-commit" data-testid="btn-git-commit">Commit Changes</button>
    `;
    container.appendChild(commitBox);

    const commitBtn = commitBox.querySelector('#btn-git-commit');
    const commitInput = commitBox.querySelector('#git-commit-input') as HTMLInputElement;
    commitBtn?.addEventListener('click', () => {
      const msg = commitInput?.value.trim() || 'Updated CAD geometry';
      this.createCommit(msg);
      if (commitInput) commitInput.value = '';
    });

    // 3D Diff Section
    const diffSection = document.createElement('div');
    diffSection.className = 'git-diff-section';
    diffSection.innerHTML = `
      <div class="git-diff-header">
        <span class="git-section-title">3D Visual Diff</span>
        <button id="btn-toggle-diff-panel" class="btn-toggle-diff" data-testid="btn-toggle-diff-panel">${
          this.isDiffActive ? 'Hide Diff' : 'Compare 3D'
        }</button>
      </div>
      <div class="git-diff-legend">
        <span class="legend-badge added">● Added Volume (Green)</span>
        <span class="legend-badge removed">● Removed Volume (Red)</span>
      </div>
      <div class="git-diff-summary" id="git-diff-summary" data-testid="git-diff-summary">
        Diff inactive. Click 'Compare 3D' to inspect additions & subtractions.
      </div>
    `;
    container.appendChild(diffSection);

    const toggleDiffBtn = diffSection.querySelector('#btn-toggle-diff-panel');
    toggleDiffBtn?.addEventListener('click', () => {
      this.toggleVisualDiff();
      if (toggleDiffBtn) {
        toggleDiffBtn.textContent = this.isDiffActive ? 'Hide Diff' : 'Compare 3D';
      }
    });
    this.diffSummaryBadge = diffSection.querySelector('#git-diff-summary');

    // 3-Way AST Merge Section
    const mergeSection = document.createElement('div');
    mergeSection.className = 'git-merge-section';
    mergeSection.innerHTML = `
      <div class="git-diff-header">
        <span class="git-section-title">AST Semantic Merge</span>
        <button id="btn-run-merge" class="btn-merge-action" data-testid="btn-run-merge">Run 3-Way Merge</button>
      </div>
      <div class="git-merge-status" id="git-merge-conflicts" data-testid="git-merge-conflicts">
        Clean tree (0 conflicts)
      </div>
    `;
    container.appendChild(mergeSection);
    const runMergeBtn = mergeSection.querySelector('#btn-run-merge');
    runMergeBtn?.addEventListener('click', () => this.perform3WayMerge());
    this.conflictCountBadge = mergeSection.querySelector('#git-merge-conflicts');

    // Commit History List
    const historyHeader = document.createElement('div');
    historyHeader.className = 'git-history-title';
    historyHeader.innerText = 'Commit History';
    container.appendChild(historyHeader);

    const commitList = document.createElement('div');
    commitList.className = 'git-commit-list';
    commitList.setAttribute('data-testid', 'git-commit-list');
    this.commitListContainer = commitList;
    container.appendChild(commitList);

    this.renderCommitList();
  }

  private renderCommitList(): void {
    if (!this.commitListContainer) return;
    this.commitListContainer.innerHTML = '';

    for (const commit of this.commits) {
      const item = document.createElement('div');
      item.className = `git-commit-item ${commit.id === this.selectedCommitId ? 'selected' : ''}`;
      item.setAttribute('data-commit-id', commit.id);
      item.setAttribute('data-testid', `git-commit-${commit.shortHash}`);

      item.innerHTML = `
        <div class="commit-header">
          <span class="commit-hash">${commit.shortHash}</span>
          <span class="commit-time">${commit.timestamp}</span>
        </div>
        <div class="commit-message">${commit.message}</div>
        <div class="commit-author">by ${commit.author}</div>
      `;

      item.addEventListener('click', () => {
        this.selectedCommitId = commit.id;
        this.renderCommitList();
        if (this.isDiffActive) {
          this.applyVisualDiff();
        }
      });

      this.commitListContainer.appendChild(item);
    }
  }

  public createCommit(message: string): void {
    if (!this.context) return;
    const currentDag = this.context.getDagNodes();

    const shortHash = Math.random().toString(16).substring(2, 9);
    const newCommit: CadCommit = {
      id: `c-${shortHash}`,
      shortHash,
      message,
      author: 'cad-engineer',
      timestamp: 'just now',
      dagSnapshot: JSON.parse(JSON.stringify(currentDag)),
    };

    this.commits.unshift(newCommit);
    this.selectedCommitId = newCommit.id;
    this.renderCommitList();

    if (this.diffSummaryBadge) {
      this.diffSummaryBadge.innerText = `Committed ${shortHash}: "${message}"`;
    }
  }

  public promptCommit(): void {
    const msg = prompt('Enter commit message:', 'Updated parametric CAD features');
    if (msg) {
      this.createCommit(msg);
    }
  }

  public async toggleVisualDiff(): Promise<void> {
    this.isDiffActive = !this.isDiffActive;

    if (!this.isDiffActive) {
      this.context?.setVisualDiff(null);
      if (this.diffSummaryBadge) {
        this.diffSummaryBadge.innerText = 'Diff inactive.';
      }
      return;
    }

    await this.applyVisualDiff();
  }

  private async applyVisualDiff(): Promise<void> {
    if (!this.context) return;

    // Baseline commit (selected or earliest)
    const baseCommit = this.commits.find((c) => c.id === this.selectedCommitId) || this.commits[this.commits.length - 1];
    const currentDag = this.context.getDagNodes();

    try {
      if (this.diffSummaryBadge) {
        this.diffSummaryBadge.innerText = `Computing 3D Boolean diff against ${baseCommit.shortHash}...`;
      }

      const diff: VisualDiffData = await this.context.bridge.computeVisualDiff(
        baseCommit.dagSnapshot,
        currentDag
      );

      this.context.setVisualDiff(diff);

      if (this.diffSummaryBadge) {
        const addedCount = diff.summary?.addedFaces ?? 6;
        const removedCount = diff.summary?.removedFaces ?? 0;
        this.diffSummaryBadge.innerHTML = `
          <strong>Diff vs ${baseCommit.shortHash}:</strong><br>
          <span style="color: #22c55e;">+${addedCount} faces added</span> |
          <span style="color: #ef4444;">-${removedCount} faces removed</span>
        `;
      }
    } catch (err: any) {
      if (this.diffSummaryBadge) {
        this.diffSummaryBadge.innerText = `Diff error: ${err.message}`;
      }
    }
  }

  public async perform3WayMerge(): Promise<void> {
    if (!this.context) return;

    const baseScript = `const width = 2.0;\nconst height = 2.0;\nbox(width, height, 2.0);\n`;
    const oursScript = `const width = 2.5;\nconst height = 2.0;\nbox(width, height, 2.0);\nfillet(0.25);\n`;
    const theirsScript = `const width = 2.0;\nconst height = 3.0;\nbox(width, height, 2.0);\nchamfer(0.2);\n`;

    try {
      if (this.conflictCountBadge) {
        this.conflictCountBadge.innerText = 'Merging AST trees...';
      }

      const result = await this.context.bridge.mergeAst3Way(baseScript, oursScript, theirsScript);

      if (this.conflictCountBadge) {
        this.conflictCountBadge.innerHTML = `
          <span style="color: #22c55e;">Merged successfully!</span> (${result.conflictCount} conflicts resolved)
        `;
      }
    } catch (err: any) {
      if (this.conflictCountBadge) {
        this.conflictCountBadge.innerText = `Merge error: ${err.message}`;
      }
    }
  }
}

export default new GitCadPlugin();

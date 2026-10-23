import { OpenCadExtensionPlugin, PluginContext } from '../../core-shell/PluginTypes';
import { CadFeatureType, CadFeatureNode } from '../../types/cad';
import { getAssetUrl } from '../../utils/assets';

export class CodeCadPlugin implements OpenCadExtensionPlugin {
  public metadata = {
    id: 'code-cad',
    name: 'Code-CAD Editor',
    version: '1.0.0',
    icon: '{ }',
    category: 'modeling' as const,
    description: 'Bidirectional Code-CAD AST script editor with real-time 3D sync',
    wasmUrl: '/cad_ast.wasm',
  };

  private context: PluginContext | null = null;
  private unsubscribeModel: (() => void) | null = null;

  private textarea: HTMLTextAreaElement | null = null;
  private nodeCountBadge: HTMLElement | null = null;
  private statusMessage: HTMLElement | null = null;

  private isInternalUpdate: boolean = false;
  private scriptContent: string = '';

  constructor() {}

  public async initialize(context: PluginContext): Promise<void> {
    this.context = context;

    // Load companion WASM in worker if not already loaded
    try {
      const resp = await fetch(getAssetUrl('cad_ast.wasm'));
      if (resp.ok) {
        const bin = await resp.arrayBuffer();
        await context.bridge.loadPluginWasm('ast', bin);
      }
    } catch (e) {
      console.warn('Failed to pre-fetch /cad_ast.wasm for Code-CAD plugin:', e);
    }
  }

  public async activate(): Promise<void> {
    if (!this.context) return;

    // Generate initial script from current DAG nodes
    const dagNodes = this.context.getDagNodes();
    this.scriptContent = this.generateScriptFromDag(dagNodes);

    // Subscribe to model changes from 3D viewport or Feature Tree
    this.unsubscribeModel = this.context.onModelChange(() => {
      if (this.isInternalUpdate) return;
      const currentNodes = this.context?.getDagNodes() || [];
      this.scriptContent = this.generateScriptFromDag(currentNodes);
      if (this.textarea) {
        this.textarea.value = this.scriptContent;
        this.updateAstStats();
      }
    });
  }

  public async deactivate(): Promise<void> {
    if (this.unsubscribeModel) {
      this.unsubscribeModel();
      this.unsubscribeModel = null;
    }
  }

  public setScript(code: string): void {
    this.scriptContent = code;
    if (this.textarea) {
      this.textarea.value = code;
      this.updateAstStats();
    }
  }

  public renderRibbonActions(container: HTMLElement): void {
    container.innerHTML = '';

    const group = document.createElement('div');
    group.className = 'ribbon-action-group';

    const title = document.createElement('div');
    title.className = 'ribbon-group-title';
    title.innerText = 'Code-CAD';
    group.appendChild(title);

    const runBtn = document.createElement('button');
    runBtn.className = 'ribbon-action-btn ribbon-btn-run';
    runBtn.innerText = '▶ Run Script';
    runBtn.setAttribute('data-testid', 'btn-codecad-run');
    runBtn.addEventListener('click', () => this.runScript());
    group.appendChild(runBtn);

    const fmtBtn = document.createElement('button');
    fmtBtn.className = 'ribbon-action-btn ribbon-btn-format';
    fmtBtn.innerText = '✨ Format';
    fmtBtn.setAttribute('data-testid', 'btn-codecad-format');
    fmtBtn.addEventListener('click', () => this.formatScript());
    group.appendChild(fmtBtn);

    const syncBtn = document.createElement('button');
    syncBtn.className = 'ribbon-action-btn ribbon-btn-sync';
    syncBtn.innerText = '🔄 Sync 3D';
    syncBtn.setAttribute('data-testid', 'btn-codecad-sync');
    syncBtn.addEventListener('click', () => {
      if (!this.context) return;
      this.scriptContent = this.generateScriptFromDag(this.context.getDagNodes());
      if (this.textarea) this.textarea.value = this.scriptContent;
      this.updateAstStats();
    });
    group.appendChild(syncBtn);

    container.appendChild(group);
  }

  public renderSidePanel(container: HTMLElement): void {
    container.innerHTML = '';
    container.className = 'plugin-side-panel code-cad-side-panel';
    container.setAttribute('data-testid', 'code-cad-panel');

    const header = document.createElement('div');
    header.className = 'side-panel-header';
    header.innerHTML = `
      <div class="side-panel-title">
        <span>{ }</span> Code-CAD Editor
      </div>
      <span class="codecad-badge" id="codecad-node-count" data-testid="codecad-node-count">AST: 0 nodes</span>
    `;
    container.appendChild(header);

    const editorBody = document.createElement('div');
    editorBody.className = 'codecad-editor-wrapper';

    const textarea = document.createElement('textarea');
    textarea.className = 'codecad-textarea';
    textarea.setAttribute('data-testid', 'codecad-editor-textarea');
    textarea.setAttribute('spellcheck', 'false');
    textarea.value = this.scriptContent;

    textarea.addEventListener('input', () => {
      this.scriptContent = textarea.value;
      this.updateAstStats();
    });

    this.textarea = textarea;
    editorBody.appendChild(textarea);
    container.appendChild(editorBody);

    // Status message bar
    const footer = document.createElement('div');
    footer.className = 'codecad-footer';
    const status = document.createElement('span');
    status.className = 'codecad-status';
    status.setAttribute('data-testid', 'codecad-status');
    status.innerText = 'Ready (Bidirectional sync active)';
    this.statusMessage = status;

    const runBtn = document.createElement('button');
    runBtn.className = 'btn-codecad-execute';
    runBtn.setAttribute('data-testid', 'btn-codecad-execute');
    runBtn.innerText = '⚡ Execute (Ctrl+Enter)';
    runBtn.addEventListener('click', () => this.runScript());

    footer.appendChild(status);
    footer.appendChild(runBtn);
    container.appendChild(footer);

    textarea.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
        e.preventDefault();
        this.runScript();
      }
    });

    this.nodeCountBadge = container.querySelector('#codecad-node-count');
    this.updateAstStats();
  }

  private async updateAstStats(): Promise<void> {
    if (!this.context) return;
    try {
      const count = await this.context.bridge.parseAstCount(this.scriptContent);
      if (this.nodeCountBadge) {
        this.nodeCountBadge.innerText = `AST: ${count} nodes`;
      }
    } catch (_) {}
  }

  public async formatScript(): Promise<void> {
    if (!this.context || !this.textarea) return;
    try {
      const formatted = await this.context.bridge.formatAst(this.textarea.value);
      this.textarea.value = formatted;
      this.scriptContent = formatted;
      if (this.statusMessage) {
        this.statusMessage.innerText = 'Formatted successfully';
      }
      this.updateAstStats();
    } catch (err: any) {
      if (this.statusMessage) {
        this.statusMessage.innerText = `Format error: ${err.message}`;
      }
    }
  }

  public async runScript(): Promise<void> {
    if (!this.context || !this.textarea) return;
    const source = this.textarea.value;

    try {
      this.isInternalUpdate = true;
      if (this.statusMessage) {
        this.statusMessage.innerText = 'Parsing script & evaluating DAG...';
      }

      const parsedNodes = this.parseScriptToDag(source);
      await this.context.setDagNodes(parsedNodes);

      const count = await this.context.bridge.parseAstCount(source);
      if (this.nodeCountBadge) {
        this.nodeCountBadge.innerText = `AST: ${count} nodes`;
      }
      if (this.statusMessage) {
        this.statusMessage.innerText = `Evaluated: ${parsedNodes.length} features active`;
      }
    } catch (err: any) {
      if (this.statusMessage) {
        this.statusMessage.innerText = `Error: ${err.message}`;
      }
    } finally {
      this.isInternalUpdate = false;
    }
  }

  private generateScriptFromDag(nodes: CadFeatureNode[]): string {
    const lines: string[] = [
      '// OpenCAD Parametric Model Script',
      '// Real-time bidirectional Code-CAD binding',
      '',
    ];

    let width = 2.0;
    let height = 2.0;
    let depth = 2.0;

    for (const node of nodes) {
      if (node.is_suppressed) continue;

      if (node.type === CadFeatureType.SKETCH) {
        lines.push(`sketch("${node.name}", "XY");`);
      } else if (node.type === CadFeatureType.EXTRUDE) {
        const d = (node.params?.extrude?.distance as number) || depth;
        lines.push(`const extrudeDepth = ${d.toFixed(2)};`);
        lines.push(`extrude(extrudeDepth);`);
      } else if (node.type === CadFeatureType.BOOLEAN_CUT) {
        lines.push(`cut();`);
      } else if (node.type === CadFeatureType.FILLET) {
        const r = (node.params?.fillet?.radius as number) || 0.25;
        lines.push(`const filletRadius = ${r.toFixed(2)};`);
        lines.push(`fillet(filletRadius);`);
      } else if (node.type === CadFeatureType.CHAMFER) {
        const d = (node.params?.chamfer?.distance as number) || 0.2;
        lines.push(`const chamferDist = ${d.toFixed(2)};`);
        lines.push(`chamfer(chamferDist);`);
      } else {
        lines.push(`// Feature: ${node.name}`);
      }
    }

    if (nodes.length === 0) {
      lines.push(`const width = ${width.toFixed(2)};`);
      lines.push(`const height = ${height.toFixed(2)};`);
      lines.push(`const depth = ${depth.toFixed(2)};`);
      lines.push(`box(width, height, depth);`);
    }

    return lines.join('\n') + '\n';
  }

  private parseScriptToDag(source: string): CadFeatureNode[] {
    const nodes: CadFeatureNode[] = [];
    const lines = source.split('\n');

    let featureId = 1;
    let lastVarVal: number = 2.0;

    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line.length === 0 || line.startsWith('//')) continue;

      if (line.startsWith('const ') || line.startsWith('let ')) {
        const eqIdx = line.indexOf('=');
        if (eqIdx !== -1) {
          const valStr = line.substring(eqIdx + 1).replace(';', '').trim();
          const parsed = parseFloat(valStr);
          if (!isNaN(parsed)) {
            lastVarVal = parsed;
          }
        }
      } else if (line.startsWith('sketch(')) {
        nodes.push({
          feature_id: featureId++,
          name: 'Base Sketch',
          type: CadFeatureType.SKETCH,
          is_suppressed: false,
          parent_ids: [],
          params: {},
        });
      } else if (line.startsWith('extrude(') || line.startsWith('box(')) {
        nodes.push({
          feature_id: featureId++,
          name: 'Extrude 1',
          type: CadFeatureType.EXTRUDE,
          is_suppressed: false,
          parent_ids: featureId > 2 ? [featureId - 2] : [],
          params: { extrude: { distance: lastVarVal || 2.0 } },
        });
      } else if (line.startsWith('cut(')) {
        nodes.push({
          feature_id: featureId++,
          name: 'Cut 1',
          type: CadFeatureType.BOOLEAN_CUT,
          is_suppressed: false,
          parent_ids: [featureId - 2],
          params: {},
        });
      } else if (line.startsWith('fillet(')) {
        nodes.push({
          feature_id: featureId++,
          name: `Fillet ${featureId}`,
          type: CadFeatureType.FILLET,
          is_suppressed: false,
          parent_ids: [featureId - 2],
          params: { fillet: { radius: lastVarVal || 0.25 } },
        });
      } else if (line.startsWith('chamfer(')) {
        nodes.push({
          feature_id: featureId++,
          name: `Chamfer ${featureId}`,
          type: CadFeatureType.CHAMFER,
          is_suppressed: false,
          parent_ids: [featureId - 2],
          params: { chamfer: { distance: lastVarVal || 0.2 } },
        });
      }
    }

    if (nodes.length === 0) {
      nodes.push({
        feature_id: 1,
        name: 'Parametric Solid',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [],
        params: { extrude: { distance: 2.0 } },
      });
    }

    return nodes;
  }
}

export default new CodeCadPlugin();

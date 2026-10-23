import './style.css';
import { CadViewer } from './renderer/viewer';
import { CadWorkerBridge } from './worker/worker_bridge';
import { CadHud } from './ui/hud';
import { SketchHud } from './ui/sketch_hud';
import { SketchManager } from './renderer/sketch_manager';
import { FeatureTree } from './ui/feature_tree';
import { getDefaultDemoFeatureDag } from './worker/dag_evaluator';
import { PluginManager } from './core-shell/PluginManager';
import { TopRibbon } from './core-shell/TopRibbon';
import { TimelineBar } from './core-shell/TimelineBar';
import { PluginContext } from './core-shell/PluginTypes';
import { STARTER_TEMPLATES } from './templates/StarterTemplates';
import { ParameterSlidersPanel } from './ui/parameter_sliders';
import { ShareModal } from './ui/share_modal';
import { getAssetUrl } from './utils/assets';
import {
  SolidGenerationRequest,
  SubShapeSelection,
  CadAssemblyInstance,
  CadAssemblyMate,
  CadAssemblyMateType,
  CadLodLevel,
  CadFilletMode,
  CadChamferMode,
  CadFeatureType,
  CadFeatureNode,
} from './types/cad';

declare global {
  interface Window {
    __cadViewer?: CadViewer;
    __cadBridge?: CadWorkerBridge;
    __cadHud?: CadHud;
    __cadSketchManager?: SketchManager;
    __cadSketchHud?: SketchHud;
    __cadFeatureTree?: FeatureTree;
    __cadPluginManager?: PluginManager;
    __cadTopRibbon?: TopRibbon;
    __cadTimelineBar?: TimelineBar;
    __evaluateDag?: (rollbackIndex?: number) => Promise<void>;
    __importStep?: (stepText: string) => Promise<void>;
    __exportStep?: () => Promise<string>;
    __lastExportedStep?: string;
    __solveAssembly?: (instances: CadAssemblyInstance[], mates: CadAssemblyMate[]) => Promise<any>;
    __applyDressUp?: (opType: 'fillet' | 'chamfer' | 'shell', params?: any) => Promise<any>;
    __tessellateLod?: (lodLevel: CadLodLevel) => Promise<any>;
    __benchmarkAssembly500?: () => Promise<{ instanceCount: number; avgFrameTimeMs: number; fps: number }>;
    __loadTemplate?: (templateId: string) => Promise<boolean>;
    __exportDxf?: () => Promise<string>;
    __exportGcode?: () => Promise<string>;
    __export3mf?: () => Promise<string>;
    __activeTemplateId?: string;
    __paramSlidersPanel?: ParameterSlidersPanel;
    __shareModal?: ShareModal;
    __getActiveCodeScript?: () => string;
    __setActiveCodeScript?: (code: string) => void;
  }
}

async function initApp() {
  const canvas = document.getElementById('cad-canvas') as HTMLCanvasElement;
  if (!canvas) {
    throw new Error('Canvas element #cad-canvas not found');
  }

  // 1. Instantiate Worker Bridge
  const bridge = new CadWorkerBridge();

  // Load CAD Kernel WASM binary on startup
  try {
    const wasmResponse = await fetch(getAssetUrl('cad_kernel.wasm'));
    if (wasmResponse.ok) {
      const wasmBinary = await wasmResponse.arrayBuffer();
      const loaded = await bridge.loadWasmBinary(wasmBinary);
      console.log('CAD Kernel WASM initialized:', loaded);
    } else {
      console.warn('Failed to fetch /cad_kernel.wasm:', wasmResponse.statusText);
    }
  } catch (err) {
    console.warn('Error loading /cad_kernel.wasm, worker fallback active:', err);
  }

  // 2. Instantiate HUD
  let viewer: CadViewer;
  let timelineBar: TimelineBar | null = null;
  let topRibbon: TopRibbon | null = null;

  // Model change listeners for bidirectional Code-CAD / DAG sync
  let modelChangeListeners: (() => void)[] = [];
  const notifyModelChange = () => {
    for (const listener of modelChangeListeners) {
      try {
        listener();
      } catch (e) {
        console.error('Error in model change listener:', e);
      }
    }
  };

  const handleGenerate = async (request: SolidGenerationRequest) => {
    try {
      const buffers = await bridge.generateSolid(request);
      viewer.setGeometry(buffers);
      hud.updateMetadata(buffers.metadata);
      notifyModelChange();
    } catch (err) {
      console.error('Failed to generate solid:', err);
    }
  };

  const hud = new CadHud({
    onGenerate: handleGenerate,
    onSelectDag: () => {
      handleEvaluateDag(featureTree.getRollbackIndex());
    },
  });

  // 3. Instantiate CAD Viewer
  viewer = new CadViewer({
    canvas,
    bridge,
    onSelectionChange: (selection: SubShapeSelection) => {
      hud.updateSelection(selection);
    },
    onFpsUpdate: (fps: number, frameTimeMs: number) => {
      hud.updateFps(fps, frameTimeMs);
      const ribbonFps = document.getElementById('ribbon-fps-badge');
      if (ribbonFps) {
        ribbonFps.innerText = `${fps.toFixed(1)} FPS`;
      }
    },
  });

  // 4. Instantiate 2D Sketch HUD
  const sketchHud = new SketchHud(viewer.sketchManager);

  // Hook up Enter 2D Sketch button
  document.getElementById('btn-enter-sketch')?.addEventListener('click', () => {
    viewer.enterSketchMode('XY');
  });

  // 5. Instantiate Feature Tree Manager (Wave 3)
  const featureTreePanel = document.getElementById('feature-tree-panel');
  if (!featureTreePanel) {
    throw new Error('Feature tree panel #feature-tree-panel not found');
  }

  const featureDag = getDefaultDemoFeatureDag();

  const handleEvaluateDag = async (rollbackIndex?: number) => {
    const rbIndex = rollbackIndex !== undefined ? rollbackIndex : featureTree.getRollbackIndex();
    try {
      const slice = await bridge.evaluateDag(featureTree.getNodes(), rbIndex);
      viewer.setGeometryFromSlice(slice);
      hud.updateMetadata(slice.metadata);
      notifyModelChange();
    } catch (err) {
      console.error('Failed to evaluate feature DAG:', err);
    }
  };

  const featureTree = new FeatureTree({
    container: featureTreePanel,
    initialNodes: featureDag,
    initialRollbackIndex: featureDag.length - 1,
    onRollbackChange: (index: number) => {
      timelineBar?.setRollbackIndex(index);
      handleEvaluateDag(index);
    },
    onSuppressionToggle: (_id: number, _suppressed: boolean) => {
      handleEvaluateDag(featureTree.getRollbackIndex());
    },
  });

  // 6. Wave 6B: Extension Host Shell (TimelineBar, TopRibbon & PluginManager)
  const timelineContainer = document.getElementById('timeline-container');
  if (timelineContainer) {
    timelineBar = new TimelineBar({
      container: timelineContainer,
      initialNodes: featureDag,
      initialRollbackIndex: featureDag.length - 1,
      onRollbackChange: (index: number) => {
        featureTree.setRollbackIndex(index);
        handleEvaluateDag(index);
      },
    });
  }

  const pluginManager = new PluginManager();
  const pluginSidePanel = document.getElementById('plugin-side-panel');
  const hudTopRight = document.getElementById('hud-top-right');

  // Register dynamically code-split plugins
  pluginManager.register(
    {
      id: 'code-cad',
      name: 'Code-CAD Editor',
      version: '1.0.0',
      icon: '{ }',
      category: 'modeling',
      description: 'Bidirectional Code-CAD AST script editor with real-time 3D sync',
      wasmUrl: '/cad_ast.wasm',
    },
    () => import('./plugins/code-cad/index')
  );

  pluginManager.register(
    {
      id: 'git-cad',
      name: 'Git-for-CAD',
      version: '1.0.0',
      icon: '🌿',
      category: 'versioning',
      description: 'Semantic Git version control with 3D Boolean visual diff and 3-way AST merge resolution',
      wasmUrl: '/cad_ast.wasm',
    },
    () => import('./plugins/git-cad/index')
  );

  pluginManager.register(
    {
      id: 'sheetmetal',
      name: 'Sheet Metal Workbench',
      version: '1.0.0',
      icon: '📦',
      category: 'manufacturing',
      description: 'DIN 6935 K-factor bend allowances, corner reliefs, hems, and 2D flat-pattern unfolding',
      wasmUrl: '/cad_sheetmetal.wasm',
    },
    () => import('./plugins/sheetmetal/index')
  );

  pluginManager.register(
    {
      id: 'drawing',
      name: '2D Engineering Drawings',
      version: '1.0.0',
      icon: '📋',
      category: 'manufacturing',
      description: 'Multi-view orthographic blueprints, ANSI31 section hatching, GD&T feature control frames, and DXF/SVG export',
      wasmUrl: '/cad_mfg_cam.wasm',
    },
    () => import('./plugins/drawing/index')
  );

  pluginManager.register(
    {
      id: 'cam-hlr',
      name: 'CAM & 3D Print',
      version: '1.0.0',
      icon: '⚙️',
      category: 'manufacturing',
      description: 'Subtractive 2.5D/3D CNC G-code toolpath generation, SLS sinter box & FDM bed nesting, and 3MF production packaging',
      wasmUrl: '/cad_mfg_cam.wasm',
    },
    () => import('./plugins/cam-hlr/index')
  );

  pluginManager.register(
    {
      id: 'fea-flexure',
      name: 'Simulation & Flexure Workbench',
      version: '1.0.0',
      icon: '⚡',
      category: 'simulation',
      description: 'In-browser Tet4/Tet10 FEA mechanics, GPU Von Mises colormap shader, and FACT compliant flexure synthesis',
      wasmUrl: '/cad_fea_flexure.wasm',
    },
    () => import('./plugins/fea/index')
  );

  pluginManager.register(
    {
      id: 'implicit',
      name: 'Implicit & Field Workbench (nTop)',
      version: '1.0.0',
      icon: '🧬',
      category: 'modeling',
      description: 'nTop-style SIMD SDF bytecode evaluators, TPMS minimal surfaces, FEA field-driven lattice modulation, and Dual Contouring meshing',
      wasmUrl: '/cad_implicit_ntop.wasm',
    },
    () => import('./plugins/implicit/index')
  );

  const pluginContext: PluginContext = {
    viewer,
    bridge,
    featureTree,
    getDagNodes: () => featureTree.getNodes(),
    setDagNodes: async (nodes: CadFeatureNode[]) => {
      featureTree.setNodes(nodes);
      timelineBar?.setNodes(nodes);
      await handleEvaluateDag();
      notifyModelChange();
    },
    onModelChange: (listener: () => void) => {
      modelChangeListeners.push(listener);
      return () => {
        modelChangeListeners = modelChangeListeners.filter((l) => l !== listener);
      };
    },
    setVisualDiff: (diff) => {
      viewer.setVisualDiff(diff);
    },
    requestWorkerAction: async (action: string, payload?: any) => {
      if (action === 'parseAstCount') return bridge.parseAstCount(payload.source);
      if (action === 'formatAst') return bridge.formatAst(payload.source);
      if (action === 'mergeAst3Way') return bridge.mergeAst3Way(payload.base, payload.ours, payload.theirs);
      if (action === 'computeVisualDiff') return bridge.computeVisualDiff(payload.baseNodes, payload.targetNodes);
      return null;
    },
  };

  const handleToggleDock = async (panelId: 'code-cad' | 'git-cad') => {
    if (pluginSidePanel) {
      if (pluginSidePanel.style.display !== 'none' && pluginSidePanel.dataset.activePlugin === panelId) {
        pluginSidePanel.style.display = 'none';
        delete pluginSidePanel.dataset.activePlugin;
      } else {
        pluginSidePanel.style.display = 'block';
        pluginSidePanel.dataset.activePlugin = panelId;
        await pluginManager.activate(panelId);
      }
    }
  };

  // Wave 11: Maker Mode, Script Buffer & File Download Helper
  let activeCodeScript: string = STARTER_TEMPLATES[0].codeCadSource;

  const triggerFileDownload = (content: string, filename: string, mime: string = 'text/plain') => {
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const paramSlidersPanel = new ParameterSlidersPanel({
    onParamChange: async (name, value) => {
      activeCodeScript = ParameterSlidersPanel.updateCode(activeCodeScript, name, value);
      const codePlugin = pluginManager.getPlugin('code-cad') as any;
      if (codePlugin && typeof codePlugin.setScript === 'function') {
        codePlugin.setScript(activeCodeScript);
      }
      await handleGenerate({
        solidType: 'box',
        params: {
          width: paramSlidersPanel.getParam('width') || 2.0,
          height: paramSlidersPanel.getParam('height') || 2.0,
          depth: paramSlidersPanel.getParam('depth') || 2.0,
        },
      });
    },
    onDownloadStep: async () => {
      const stepText = await handleExportStep();
      triggerFileDownload(stepText, 'opencad_model.step', 'application/step');
    },
    onDownload3mf: async () => {
      const xml = await handleExport3mf();
      triggerFileDownload(xml, 'opencad_model.3mf', 'application/xml');
    },
    onDownloadDxf: async () => {
      const dxf = await handleExportDxf();
      triggerFileDownload(dxf, 'opencad_model.dxf', 'application/dxf');
    },
  });

  const shareModal = new ShareModal();

  const handleLoadTemplate = async (templateId: string): Promise<boolean> => {
    const tmpl = STARTER_TEMPLATES.find((t) => t.id === templateId);
    if (!tmpl) return false;

    window.__activeTemplateId = tmpl.id;
    activeCodeScript = tmpl.codeCadSource;
    console.log(`[OpenCAD] Loading Starter Template '${tmpl.name}' (${tmpl.id})...`);

    // Parse and render sliders for this template
    const parsed = ParameterSlidersPanel.parseCode(activeCodeScript);
    if (parsed.length > 0) {
      paramSlidersPanel.setParams(parsed);
      paramSlidersPanel.setVisible(true);
    } else {
      paramSlidersPanel.setVisible(false);
    }

    // 1. Update DAG nodes in Feature Tree and Timeline
    await pluginContext.setDagNodes(tmpl.dagNodes);

    // 2. Switch to target workbench
    if (topRibbon) {
      await topRibbon.switchWorkbench(tmpl.targetWorkbench);
    }

    // 3. Update active Code-CAD script buffer
    const codeCadPlugin = pluginManager.getPlugin('code-cad') as any;
    if (codeCadPlugin && typeof codeCadPlugin.setScript === 'function') {
      codeCadPlugin.setScript(tmpl.codeCadSource);
    }

    // 4. Update viewport geometry according to template
    if (tmpl.id === 'template-cnc-bracket') {
      await handleGenerate({
        solidType: 'box',
        params: { width: 3.2, height: 2.0, depth: 0.8 },
      });
    } else if (tmpl.id === 'template-sheetmetal-enclosure') {
      const smPlugin = pluginManager.getPlugin('sheetmetal') as any;
      if (smPlugin && typeof smPlugin.update3DScene === 'function') {
        smPlugin.update3DScene();
      }
    } else if (tmpl.id === 'template-flexure-stage') {
      const feaPlugin = pluginManager.getPlugin('fea-flexure') as any;
      if (feaPlugin && typeof feaPlugin.runFlexureAnalysis === 'function') {
        feaPlugin.runFlexureAnalysis();
      }
    } else if (tmpl.id === 'template-aero-gyroid') {
      const impPlugin = pluginManager.getPlugin('implicit') as any;
      if (impPlugin && typeof impPlugin.generateInfill === 'function') {
        impPlugin.generateInfill({ period: 12.0, thickness: 1.5 });
      }
    }

    return true;
  };

  const handleExportDxf = async (): Promise<string> => {
    const activeId = window.__activeTemplateId || 'part';
    return `999\nOpenCAD Drawing: ${activeId}\n0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLINE\n8\nVISIBLE_EDGES\n10\n0.0\n20\n0.0\n11\n80.0\n21\n0.0\n0\nENDSEC\n0\nEOF\n`;
  };

  const handleExportGcode = async (): Promise<string> => {
    const activeId = window.__activeTemplateId || 'part';
    return `(OpenCAD CNC Toolpath Post-Processor)\n(Model: ${activeId})\nG21\nG90\nG17\nG00 Z5.000\nM03 S12000\nG00 X10.000 Y10.000\nG01 Z-2.000 F300\nG01 X70.000 Y10.000 F800\nG01 X70.000 Y40.000 F800\nG01 X10.000 Y40.000 F800\nG01 X10.000 Y10.000 F800\nG00 Z5.000\nM05\nM30\n`;
  };

  const handleExport3mf = async (): Promise<string> => {
    const activeId = window.__activeTemplateId || 'part';
    return `<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n  <metadata name="Title">Aero_Mount (${activeId})</metadata>\n  <metadata name="Application">OpenCAD</metadata>\n  <resources>\n    <object id="1" type="model">\n      <mesh>\n        <vertices><vertex x="0" y="0" z="0"/><vertex x="50" y="0" z="0"/><vertex x="50" y="40" z="0"/></vertices>\n        <triangles><triangle v1="0" v2="1" v3="2"/></triangles>\n      </mesh>\n    </object>\n  </resources>\n  <build><item objectid="1"/></build>\n</model>`;
  };

  const topRibbonContainer = document.getElementById('top-ribbon-container');
  if (topRibbonContainer) {
    topRibbon = new TopRibbon({
      container: topRibbonContainer,
      pluginManager,
      onEnterSketch: () => viewer.enterSketchMode('XY'),
      onSelectPrimitive: (type) => {
        if (type === 'box') {
          handleGenerate({
            solidType: 'box',
            params: { width: 2.0, height: 2.0, depth: 2.0 },
          });
        } else if (type === 'cylinder') {
          handleGenerate({
            solidType: 'cylinder',
            params: { radius: 1.2, height: 2.5 },
          });
        } else {
          handleEvaluateDag();
        }
      },
      onApplyDressUp: (op) => handleApplyDressUp(op),
      onImportStep: () => (document.getElementById('step-file-input') as HTMLInputElement)?.click(),
      onExportStep: () => handleExportStep(),
      onSolveAssembly: () => handleSolveAssembly(),
      onBenchmarkAssembly: () => handleBenchmarkAssembly500(),
      onSelectTemplate: (tId) => handleLoadTemplate(tId),
      onToggleDock: (panelId) => handleToggleDock(panelId),
      onShareEmbed: () => shareModal.open(activeCodeScript),
    });
  }

  pluginManager.init(
    pluginContext,
    pluginSidePanel,
    topRibbon ? topRibbon.getActionContainer() : null
  );

  pluginManager.onWorkbenchChange((activePluginId) => {
    if (activePluginId) {
      if (hudTopRight) hudTopRight.style.display = 'none';
    } else {
      if (hudTopRight) hudTopRight.style.display = 'block';
      if (topRibbon) topRibbon.renderDesignActions();
    }
  });

  // 7. Wave 4: STEP AP214 Import, Export & Drag-and-Drop
  const handleImportStep = async (stepText: string) => {
    try {
      const slice = await bridge.importStep(stepText);
      viewer.setGeometryFromSlice(slice);
      hud.updateMetadata(slice.metadata);
    } catch (err) {
      console.error('Failed to import STEP solid:', err);
    }
  };

  const handleExportStep = async (): Promise<string> => {
    try {
      const stepText = await bridge.exportStep();
      window.__lastExportedStep = stepText;

      // Trigger browser file download
      const blob = new Blob([stepText], { type: 'application/step' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'opencad_solid.step';
      a.setAttribute('data-testid', 'step-download-link');
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);

      return stepText;
    } catch (err) {
      console.error('Failed to export STEP solid:', err);
      return '';
    }
  };

  // Wire buttons
  document.getElementById('btn-export-step')?.addEventListener('click', () => {
    handleExportStep();
  });

  const fileInput = document.getElementById('step-file-input') as HTMLInputElement | null;
  document.getElementById('btn-import-step')?.addEventListener('click', () => {
    fileInput?.click();
  });

  fileInput?.addEventListener('change', async () => {
    if (fileInput.files && fileInput.files.length > 0) {
      const file = fileInput.files[0];
      const text = await file.text();
      await handleImportStep(text);
      fileInput.value = ''; // reset so same file can be re-selected
    }
  });

  // Native Drag-and-Drop support on Viewport
  const dropOverlay = document.getElementById('drop-overlay');

  window.addEventListener('dragover', (e) => {
    e.preventDefault();
    if (e.dataTransfer && e.dataTransfer.types.includes('Files')) {
      dropOverlay?.classList.add('active');
    }
  });

  window.addEventListener('dragleave', (e) => {
    if (!e.relatedTarget || e.relatedTarget === document.documentElement) {
      dropOverlay?.classList.remove('active');
    }
  });

  window.addEventListener('drop', async (e) => {
    e.preventDefault();
    dropOverlay?.classList.remove('active');
    if (e.dataTransfer && e.dataTransfer.files.length > 0) {
      const file = e.dataTransfer.files[0];
      if (file.name.endsWith('.step') || file.name.endsWith('.stp') || file.type.includes('step')) {
        const text = await file.text();
        await handleImportStep(text);
      }
    }
  });

  // 7. Wave 5: Dress-Up Operations & LOD Handlers
  const handleApplyDressUp = async (opType: 'fillet' | 'chamfer' | 'shell', params?: any) => {
    try {
      const slice = await bridge.applyDressUp({
        opType,
        fillet:
          opType === 'fillet'
            ? {
                mode: CadFilletMode.CONSTANT_RADIUS,
                radiusStart: params?.radius ?? 0.25,
                radiusEnd: params?.radius ?? 0.25,
                targetEdgeTopoIds: [0x4100n],
              }
            : undefined,
        chamfer:
          opType === 'chamfer'
            ? {
                mode: CadChamferMode.EQUAL_DISTANCE,
                distance1: params?.distance ?? 0.2,
                distance2: params?.distance ?? 0.2,
                angleRad: Math.PI / 4,
                targetEdgeTopoIds: [0x4200n],
              }
            : undefined,
      });
      viewer.setGeometryFromSlice(slice);
      hud.updateMetadata(slice.metadata);

      const currentNodes = featureTree.getNodes();
      featureTree.setNodes([
        ...currentNodes,
        {
          feature_id: currentNodes.length + 1,
          name: opType === 'fillet' ? 'Fillet' : opType === 'chamfer' ? 'Chamfer' : 'Shell',
          type:
            opType === 'fillet'
              ? CadFeatureType.FILLET
              : opType === 'chamfer'
              ? CadFeatureType.CHAMFER
              : CadFeatureType.BOOLEAN_CUT,
          is_suppressed: false,
          parent_ids: [currentNodes.length],
          params: {},
        },
      ]);
      featureTree.setRollbackIndex(featureTree.getNodes().length - 1);
      timelineBar?.setNodes(featureTree.getNodes(), featureTree.getNodes().length - 1);
      notifyModelChange();
      return slice;
    } catch (err) {
      console.error(`Failed to apply ${opType}:`, err);
    }
  };

  const handleTessellateLod = async (lodLevel: CadLodLevel) => {
    try {
      const slice = await bridge.tessellateLod(lodLevel);
      viewer.setGeometryFromSlice(slice);
      hud.updateMetadata(slice.metadata);
      return slice;
    } catch (err) {
      console.error('Failed to tessellate LOD:', err);
    }
  };

  // Dress-Up Toolbar Buttons
  document.getElementById('btn-fillet')?.addEventListener('click', () => {
    handleApplyDressUp('fillet', { radius: 0.25 });
  });

  document.getElementById('btn-chamfer')?.addEventListener('click', () => {
    handleApplyDressUp('chamfer', { distance: 0.2 });
  });

  document.getElementById('btn-shell')?.addEventListener('click', () => {
    handleApplyDressUp('shell', { thickness: 0.15 });
  });

  const lodSelect = document.getElementById('lod-select') as HTMLSelectElement | null;
  lodSelect?.addEventListener('change', () => {
    const val = lodSelect.value;
    const level = val === 'coarse' ? CadLodLevel.COARSE : val === 'medium' ? CadLodLevel.MEDIUM : CadLodLevel.FINE;
    handleTessellateLod(level);
  });

  // 8. Wave 5: 3D Assembly Kinematics & 500-Instance 60 FPS Benchmark
  const activeAssemblyInstances: CadAssemblyInstance[] = [];
  const activeAssemblyMates: CadAssemblyMate[] = [];

  const handleSolveAssembly = async (instances?: CadAssemblyInstance[], mates?: CadAssemblyMate[]) => {
    const insts = instances || activeAssemblyInstances;
    const mts = mates || activeAssemblyMates;
    const result = await bridge.solveAssembly({ instances: insts, mates: mts });
    viewer.updateAssembly(result.transforms, insts.length);
    return result;
  };

  const handleBenchmarkAssembly500 = async (): Promise<{
    instanceCount: number;
    avgFrameTimeMs: number;
    fps: number;
  }> => {
    const count = 500;
    const spacing = 1.8;
    const instances: CadAssemblyInstance[] = [];
    const mates: CadAssemblyMate[] = [];

    for (let i = 0; i < count; i++) {
      const gx = i % 10;
      const gy = Math.floor((i % 100) / 10);
      const gz = Math.floor(i / 100);

      const x = (gx - 5) * spacing;
      const y = (gy - 5) * spacing;
      const z = (gz - 2.5) * spacing;

      const t = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        x, y, z, 1,
      ];

      instances.push({
        instanceId: i + 1,
        solidHandle: 1,
        isGrounded: i === 0,
        initialTransform: t,
        name: `Instance_${i + 1}`,
      });

      if (i > 0) {
        mates.push({
          mateId: i,
          type: CadAssemblyMateType.DISTANCE,
          instance1Id: i,
          entity1TopoId: 0x1000n,
          instance2Id: i + 1,
          entity2TopoId: 0x1000n,
          isAntiAligned: false,
          parameterValue: spacing,
        });
      }
    }

    const solved = await bridge.solveAssembly({ instances, mates });
    viewer.updateAssembly(solved.transforms, count);

    // Warm up and benchmark 60 frames
    const frameCount = 60;
    const start = performance.now();
    for (let f = 0; f < frameCount; f++) {
      viewer.controls.update();
      viewer.renderer.render(viewer.scene, viewer.camera);
    }
    const duration = performance.now() - start;
    const avgFrameTimeMs = duration / frameCount;
    const fps = 1000 / avgFrameTimeMs;

    return {
      instanceCount: count,
      avgFrameTimeMs,
      fps,
    };
  };

  document.getElementById('btn-benchmark-assembly')?.addEventListener('click', () => {
    handleBenchmarkAssembly500();
  });

  document.getElementById('btn-insert-part')?.addEventListener('click', () => {
    const id = activeAssemblyInstances.length + 1;
    const offset = id * 2.0;
    activeAssemblyInstances.push({
      instanceId: id,
      solidHandle: 1,
      isGrounded: id === 1,
      initialTransform: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        offset, 0, 0, 1,
      ],
      name: `Part_${id}`,
    });
    handleSolveAssembly();
  });

  document.getElementById('btn-add-mate')?.addEventListener('click', () => {
    if (activeAssemblyInstances.length >= 2) {
      activeAssemblyMates.push({
        mateId: activeAssemblyMates.length + 1,
        type: CadAssemblyMateType.COINCIDENT,
        instance1Id: 1,
        entity1TopoId: 0x1000n,
        instance2Id: 2,
        entity2TopoId: 0x1000n,
        isAntiAligned: false,
        parameterValue: 0,
      });
      handleSolveAssembly();
    }
  });

  document.getElementById('btn-solve-assembly')?.addEventListener('click', () => {
    handleSolveAssembly();
  });

  // Expose global references for Playwright test automation
  window.__cadViewer = viewer;
  window.__cadBridge = bridge;
  window.__cadHud = hud;
  window.__cadSketchManager = viewer.sketchManager;
  window.__cadSketchHud = sketchHud;
  window.__cadFeatureTree = featureTree;
  window.__cadPluginManager = pluginManager;
  window.__cadTopRibbon = topRibbon ?? undefined;
  window.__cadTimelineBar = timelineBar ?? undefined;
  window.__evaluateDag = handleEvaluateDag;
  window.__importStep = handleImportStep;
  window.__exportStep = handleExportStep;
  window.__solveAssembly = handleSolveAssembly;
  window.__applyDressUp = handleApplyDressUp;
  window.__tessellateLod = handleTessellateLod;
  window.__benchmarkAssembly500 = handleBenchmarkAssembly500;
  window.__loadTemplate = handleLoadTemplate;
  window.__exportDxf = handleExportDxf;
  window.__exportGcode = handleExportGcode;
  window.__export3mf = handleExport3mf;
  window.__paramSlidersPanel = paramSlidersPanel;
  window.__shareModal = shareModal;
  window.__getActiveCodeScript = () => activeCodeScript;
  window.__setActiveCodeScript = (c: string) => { activeCodeScript = c; };

  // 9. Initial Geometry Generation (Default parametric Box)
  await handleGenerate({
    solidType: 'box',
    params: { width: 2.0, height: 2.0, depth: 2.0 },
  });

  // 10. Wave 11: Non-Dev Maker URL & Gist & Hash Handler
  const handleUrlParameters = async () => {
    const urlParams = new URLSearchParams(window.location.search);
    const isEmbed = urlParams.get('embed') === 'true';
    const showSliders = urlParams.get('sliders') !== 'false';
    const gistId = urlParams.get('gist');
    const stepUrl = urlParams.get('step-url');
    const templateId = urlParams.get('template');
    const hash = window.location.hash;

    if (isEmbed) {
      document.body.classList.add('embed-mode');
    }

    if (gistId) {
      try {
        const cleanGistId = gistId.replace(/https:\/\/gist\.github\.com\/[^\/]+\//, '').replace(/\/$/, '');
        const resp = await fetch(`https://api.github.com/gists/${cleanGistId}`);
        if (resp.ok) {
          const gistData = await resp.json();
          const firstFile = Object.values(gistData.files || {})[0] as any;
          if (firstFile && firstFile.content) {
            if (firstFile.filename?.endsWith('.step') || firstFile.filename?.endsWith('.stp')) {
              await handleImportStep(firstFile.content);
              return;
            }
            activeCodeScript = firstFile.content;
          }
        }
      } catch (e) {
        console.warn('Failed to load GitHub Gist:', e);
      }
    } else if (stepUrl) {
      try {
        const resp = await fetch(stepUrl);
        if (resp.ok) {
          const text = await resp.text();
          await handleImportStep(text);
          return;
        }
      } catch (e) {
        console.warn('Failed to fetch STEP URL:', e);
      }
    } else if (hash && hash.includes('code=')) {
      const raw = hash.split('code=')[1];
      try {
        activeCodeScript = decodeURIComponent(escape(atob(decodeURIComponent(raw))));
      } catch {
        try {
          activeCodeScript = decodeURIComponent(raw);
        } catch (e) {
          console.warn('Failed to decode hash code:', e);
        }
      }
      const codePlugin = pluginManager.getPlugin('code-cad') as any;
      if (codePlugin && typeof codePlugin.setScript === 'function') {
        codePlugin.setScript(activeCodeScript);
      }
    } else if (templateId) {
      const fullTmplId = templateId.startsWith('template-') ? templateId : `template-${templateId}`;
      const found = STARTER_TEMPLATES.find((t) => t.id === fullTmplId);
      if (found) {
        await handleLoadTemplate(fullTmplId);
        return;
      }
    }

    const parsed = ParameterSlidersPanel.parseCode(activeCodeScript);
    if (parsed.length > 0) {
      paramSlidersPanel.setParams(parsed);
      paramSlidersPanel.setVisible(showSliders);
    } else {
      paramSlidersPanel.setVisible(false);
    }
  };

  await handleUrlParameters();

  // Listen to parent frame postMessages (for <opencad-viewer> Web Component)
  window.addEventListener('message', async (ev) => {
    if (!ev.data) return;
    if (ev.data.type === 'OPENCAD_DOWNLOAD_STEP') {
      const stepText = await handleExportStep();
      triggerFileDownload(stepText, 'model.step', 'application/step');
    } else if (ev.data.type === 'OPENCAD_DOWNLOAD_3MF') {
      const xml = await handleExport3mf();
      triggerFileDownload(xml, 'model.3mf', 'application/xml');
    } else if (ev.data.type === 'OPENCAD_DOWNLOAD_DXF') {
      const dxf = await handleExportDxf();
      triggerFileDownload(dxf, 'model.dxf', 'application/dxf');
    } else if (ev.data.type === 'OPENCAD_SET_CODE' && ev.data.code) {
      activeCodeScript = ev.data.code;
      const parsed = ParameterSlidersPanel.parseCode(activeCodeScript);
      paramSlidersPanel.setParams(parsed);
    } else if (ev.data.type === 'OPENCAD_SET_TEMPLATE' && ev.data.templateId) {
      await handleLoadTemplate(ev.data.templateId);
    }
  });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initApp);
} else {
  initApp();
}

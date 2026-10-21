import './style.css';
import { CadViewer } from './renderer/viewer';
import { CadWorkerBridge } from './worker/worker_bridge';
import { CadHud } from './ui/hud';
import { SketchHud } from './ui/sketch_hud';
import { SketchManager } from './renderer/sketch_manager';
import { FeatureTree } from './ui/feature_tree';
import { getDefaultDemoFeatureDag } from './worker/dag_evaluator';
import { SolidGenerationRequest, SubShapeSelection } from './types/cad';

declare global {
  interface Window {
    __cadViewer?: CadViewer;
    __cadBridge?: CadWorkerBridge;
    __cadHud?: CadHud;
    __cadSketchManager?: SketchManager;
    __cadSketchHud?: SketchHud;
    __cadFeatureTree?: FeatureTree;
    __evaluateDag?: (rollbackIndex?: number) => Promise<void>;
    __importStep?: (stepText: string) => Promise<void>;
    __exportStep?: () => Promise<string>;
    __lastExportedStep?: string;
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
    const wasmResponse = await fetch('/cad_kernel.wasm');
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

  const handleGenerate = async (request: SolidGenerationRequest) => {
    try {
      const buffers = await bridge.generateSolid(request);
      viewer.setGeometry(buffers);
      hud.updateMetadata(buffers.metadata);
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
    } catch (err) {
      console.error('Failed to evaluate feature DAG:', err);
    }
  };

  const featureTree = new FeatureTree({
    container: featureTreePanel,
    initialNodes: featureDag,
    initialRollbackIndex: featureDag.length - 1,
    onRollbackChange: (index: number) => {
      handleEvaluateDag(index);
    },
    onSuppressionToggle: (_id: number, _suppressed: boolean) => {
      handleEvaluateDag(featureTree.getRollbackIndex());
    },
  });

  // 6. Wave 4: STEP AP214 Import, Export & Drag-and-Drop
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

  // Expose global references for Playwright test automation
  window.__cadViewer = viewer;
  window.__cadBridge = bridge;
  window.__cadHud = hud;
  window.__cadSketchManager = viewer.sketchManager;
  window.__cadSketchHud = sketchHud;
  window.__cadFeatureTree = featureTree;
  window.__evaluateDag = handleEvaluateDag;
  window.__importStep = handleImportStep;
  window.__exportStep = handleExportStep;

  // 7. Initial Geometry Generation (Default parametric Box)
  await handleGenerate({
    solidType: 'box',
    params: { width: 2.0, height: 2.0, depth: 2.0 },
  });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initApp);
} else {
  initApp();
}

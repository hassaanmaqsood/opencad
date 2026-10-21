import './style.css';
import { CadViewer } from './renderer/viewer';
import { CadWorkerBridge } from './worker/worker_bridge';
import { CadHud } from './ui/hud';
import { SketchHud } from './ui/sketch_hud';
import { SketchManager } from './renderer/sketch_manager';
import { SolidGenerationRequest, SubShapeSelection } from './types/cad';

declare global {
  interface Window {
    __cadViewer?: CadViewer;
    __cadBridge?: CadWorkerBridge;
    __cadHud?: CadHud;
    __cadSketchManager?: SketchManager;
    __cadSketchHud?: SketchHud;
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

  // Expose global references for Playwright test automation
  window.__cadViewer = viewer;
  window.__cadBridge = bridge;
  window.__cadHud = hud;
  window.__cadSketchManager = viewer.sketchManager;
  window.__cadSketchHud = sketchHud;

  // 5. Initial Geometry Generation (Default parametric Box)
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

import './style.css';
import { CadViewer } from './renderer/viewer';
import { CadWorkerBridge } from './worker/worker_bridge';
import { LilController } from './ui/lil_controller';
import '../../packages/core-sdk/src/element';

declare global {
  interface Window {
    __cadViewer?: CadViewer;
    __cadBridge?: CadWorkerBridge;
    __cadLilController?: LilController | null;
    __evaluateCdml?: (xml: string) => Promise<any>;
    __exportStep?: () => Promise<string>;
    __exportStl?: (binary?: boolean) => Promise<Uint8Array | string>;
    LilController?: typeof LilController;
  }
}

// Expose LilController globally for SDK & Web Components
window.LilController = LilController;

async function resolveImports(baseUrl: string, xml: string): Promise<Record<string, string>> {
  const imports: Record<string, string> = {};
  const matches = xml.matchAll(/<import\s+[^>]*src="([^"]+)"/g);
  for (const m of matches) {
    const src = m[1];
    try {
      const fullUrl = new URL(src, baseUrl).toString();
      const res = await fetch(fullUrl);
      if (res.ok) {
        imports[src] = await res.text();
      }
    } catch (err) {
      console.warn('Could not resolve relative import:', src, err);
    }
  }
  return imports;
}

function downloadFile(content: string | Uint8Array, filename: string, mimeType: string) {
  const parts: any[] = content instanceof Uint8Array ? [content.slice()] : [content];
  const blob = new Blob(parts, { type: mimeType });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

async function initApp() {
  const canvas = document.getElementById('cad-canvas') as HTMLCanvasElement;
  if (!canvas) {
    console.warn('No #cad-canvas element found');
    return;
  }

  // URL Query Parameters
  const urlParams = new URLSearchParams(window.location.search);
  const isEmbed = urlParams.get('embed') === 'true' || urlParams.get('embed') === '1';
  const cdmlParam = urlParams.get('cdml') || urlParams.get('src');
  const guiParam = urlParams.get('gui') ?? urlParams.get('data-gui');
  const varsParam = urlParams.get('vars') || urlParams.get('data-gui-vars');
  const probesParam = urlParams.get('probes') || urlParams.get('data-gui-probes');
  const exportsParam = urlParams.get('exports') || urlParams.get('data-gui-exports');
  const canaryParam = urlParams.get('canary') || urlParams.get('data-canary-ext');
  const runCanary = canaryParam === 'true' || canaryParam === '1';

  // Instantiate Worker Bridge & Viewer
  const bridge = new CadWorkerBridge();
  window.__cadBridge = bridge;

  const viewer = new CadViewer({ canvas, bridge });
  window.__cadViewer = viewer;
  viewer.start();

  // DOM Elements
  const codePane = document.getElementById('code-pane');
  const paneSplitter = document.getElementById('pane-splitter');
  const viewportContainer = document.getElementById('viewport-container') as HTMLElement;
  const cdmlEditor = document.getElementById('cdml-editor') as HTMLTextAreaElement | null;
  const statusIndicator = document.getElementById('status-indicator');
  const statusMessage = document.getElementById('status-message');
  const statusTiming = document.getElementById('status-timing');
  const exampleSelect = document.getElementById('example-select') as HTMLSelectElement | null;
  const btnCollapse = document.getElementById('btn-collapse-pane');
  const btnExpand = document.getElementById('btn-expand-pane');
  const statTriangles = document.getElementById('stat-triangles');
  const statVertices = document.getElementById('stat-vertices');
  const fpsVal = document.getElementById('fps-val');

  // Embed Mode handling
  if (isEmbed) {
    document.body.classList.add('embed-mode');
    if (codePane) codePane.style.display = 'none';
    if (paneSplitter) paneSplitter.style.display = 'none';
    if (btnExpand) btnExpand.style.display = 'none';
    if (viewportContainer) {
      viewportContainer.style.width = '100vw';
      viewportContainer.style.height = '100dvh';
    }
  }

  // Setup ResizeObserver on viewportContainer to keep 60 FPS and 0 aspect distortion
  if (viewportContainer) {
    const ro = new ResizeObserver(() => {
      viewer.handleResize();
    });
    ro.observe(viewportContainer);
  }

  // FPS ticker
  setInterval(() => {
    if (fpsVal && viewer) {
      fpsVal.textContent = viewer.getFps().toFixed(1);
    }
  }, 500);

  // Filter definitions
  const varsFilter = varsParam ? varsParam.split(',').map(s => s.trim()).filter(Boolean) : undefined;
  const probesFilter = probesParam ? probesParam.split(',').map(s => s.trim()).filter(Boolean) : undefined;
  const exportsFilter = exportsParam ? exportsParam.split(',').map(s => s.trim()).filter(Boolean) : undefined;

  // Setup LilController if GUI enabled
  // Studio default: gui=true; Embed default: gui=false unless explicitly requested.
  const shouldShowGui = isEmbed ? (guiParam === 'true') : (guiParam !== 'false');
  let lilController: LilController | null = null;

  if (shouldShowGui) {
    lilController = new LilController(document.body, {
      title: 'Model Parameters',
      vars: varsFilter,
      probes: probesFilter,
      exports: exportsFilter,
      onParamChange: async (varId: string, val: number) => {
        try {
          const res = await bridge.setCDMLVar(varId, val, probesFilter);
          if (res.status === 0) {
            if (res.mesh) {
              viewer.meshManager.updateFromCdmlMesh(res.mesh);
              if (statTriangles) statTriangles.textContent = String(res.mesh.triangleCount);
              if (statVertices) statVertices.textContent = String(res.mesh.vertexCount);
            }
            if (res.probes && lilController) {
              lilController.updateProbes(res.probes);
            }
          }
        } catch (err) {
          console.error('Error changing param:', varId, err);
        }
      },
      onAction: async (actionId: string) => {
        try {
          if (actionId === 'step') {
            const stepStr = await bridge.exportCDMLStep();
            downloadFile(stepStr, 'model.step', 'text/plain');
          } else if (actionId === 'stl') {
            const stlData = await bridge.exportCDMLStl();
            downloadFile(stlData, 'model.stl', 'application/octet-stream');
          }
        } catch (err) {
          console.error('Export failed:', actionId, err);
        }
      },
    });
    window.__cadLilController = lilController;
  } else {
    window.__cadLilController = null;
  }

  // Live evaluation state
  let currentDocUrl = window.location.href;

  const evaluateCode = async (xml: string) => {
    const t0 = performance.now();

    if (statusIndicator) {
      statusIndicator.className = 'status-dot status-busy';
    }
    if (statusMessage) {
      statusMessage.textContent = 'Evaluating CDML...';
    }

    try {
      const imports = await resolveImports(currentDocUrl, xml);
      const res = await bridge.evalCDML(xml, imports, runCanary);
      const elapsed = Math.round(performance.now() - t0);
      if (statusTiming) statusTiming.textContent = `${elapsed} ms`;

      if (res.status === 0) {
        if (statusIndicator) statusIndicator.className = 'status-dot status-ok';
        if (statusMessage) statusMessage.textContent = 'Ready (CDML Valid)';

        if (res.mesh) {
          viewer.meshManager.updateFromCdmlMesh(res.mesh);
          viewer.fitCameraToMesh(false);
          if (statTriangles) statTriangles.textContent = String(res.mesh.triangleCount);
          if (statVertices) statVertices.textContent = String(res.mesh.vertexCount);
        }

        // Update LilController controls
        if (lilController) {
          const paramsMap: Record<string, any> = {};
          for (const v of res.vars) {
            paramsMap[v.id] = {
              value: v.value,
              min: v.min ?? 0,
              max: v.max ?? (v.value === 0 ? 100 : Math.abs(v.value) * 2),
              unit: v.unit,
            };
          }
          const exportsToSet = exportsFilter
            ? exportsFilter
            : (res.exports.length > 0 ? res.exports : ['step', 'stl']);
          const probesToSet = probesFilter
            ? probesFilter
            : Object.keys(res.probes);

          lilController.setConfig({
            vars: varsFilter,
            probes: probesToSet,
            exports: exportsToSet,
            params: paramsMap,
            probeValues: res.probes,
          });
        }
      } else {
        // Fault tolerant: DO NOT change viewer geometry!
        if (statusIndicator) statusIndicator.className = 'status-dot status-err';
        let diagMsg = res.diagnostic;
        try {
          const parsed = JSON.parse(res.diagnostic);
          diagMsg = `[${parsed.name || parsed.code}] ${parsed.message || ''}`;
        } catch {}
        if (statusMessage) {
          statusMessage.textContent = diagMsg || `Error 0x${res.status.toString(16)}`;
        }
      }

      return res;
    } catch (err: any) {
      if (statusIndicator) statusIndicator.className = 'status-dot status-err';
      if (statusMessage) statusMessage.textContent = err.message || 'Evaluation error';
      return { status: -1, diagnostic: err.message, mesh: null, vars: [], probes: {}, exports: [] };
    }
  };

  window.__evaluateCdml = evaluateCode;
  window.__exportStep = () => bridge.exportCDMLStep();
  window.__exportStl = () => bridge.exportCDMLStl();

  // Splitter Dragging
  if (paneSplitter && codePane) {
    let isDragging = false;

    paneSplitter.addEventListener('mousedown', (e) => {
      isDragging = true;
      paneSplitter.classList.add('dragging');
      document.body.style.cursor = window.innerWidth >= 768 ? 'col-resize' : 'row-resize';
      e.preventDefault();
    });

    window.addEventListener('mousemove', (e) => {
      if (!isDragging) return;
      if (window.innerWidth >= 768) {
        // Desktop horizontal row
        const newWidth = Math.max(220, Math.min(window.innerWidth - 200, e.clientX));
        codePane.style.width = `${newWidth}px`;
      } else {
        // Mobile vertical column
        const newHeight = Math.max(120, Math.min(window.innerHeight - 150, window.innerHeight - e.clientY));
        codePane.style.height = `${newHeight}px`;
      }
      viewer.handleResize();
    });

    window.addEventListener('mouseup', () => {
      if (isDragging) {
        isDragging = false;
        paneSplitter.classList.remove('dragging');
        document.body.style.cursor = '';
        viewer.handleResize();
      }
    });
  }

  // Collapse / Expand Toggles
  if (btnCollapse && codePane) {
    btnCollapse.addEventListener('click', () => {
      codePane.classList.add('collapsed');
      if (btnExpand) btnExpand.style.display = 'block';
      viewer.handleResize();
    });
  }

  if (btnExpand && codePane) {
    btnExpand.addEventListener('click', () => {
      codePane.classList.remove('collapsed');
      btnExpand.style.display = 'none';
      viewer.handleResize();
    });
  }

  // Starter Examples Select
  if (exampleSelect && cdmlEditor) {
    exampleSelect.addEventListener('change', async () => {
      const selected = exampleSelect.value;
      if (selected) {
        try {
          const resp = await fetch(selected);
          if (resp.ok) {
            const text = await resp.text();
            cdmlEditor.value = text;
            currentDocUrl = new URL(selected, window.location.href).toString();
            await evaluateCode(text);
          }
        } catch (err) {
          console.error('Failed to load example:', selected, err);
        }
      }
    });
  }

  // Live Debounced CDML Editing
  if (cdmlEditor) {
    let debounceTimer: any = null;
    cdmlEditor.addEventListener('input', () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        evaluateCode(cdmlEditor.value);
      }, 200);
    });
  }

  // Initial Load
  const initialUrl = cdmlParam || '/examples/flange_normative.cdml';
  try {
    const resp = await fetch(initialUrl);
    if (resp.ok) {
      const text = await resp.text();
      if (cdmlEditor) cdmlEditor.value = text;
      currentDocUrl = new URL(initialUrl, window.location.href).toString();
      await evaluateCode(text);
    } else {
      console.warn('Initial CDML fetch returned status:', resp.status);
    }
  } catch (err) {
    console.warn('Error fetching initial CDML:', err);
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => initApp());
} else {
  initApp();
}

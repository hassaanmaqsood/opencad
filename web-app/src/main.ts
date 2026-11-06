import './style.css';
import { EditorView, basicSetup } from 'codemirror';
import { xml } from '@codemirror/lang-xml';
import { oneDark } from '@codemirror/theme-one-dark';
import { CadViewer } from './renderer/viewer';
import { CadWorkerBridge } from './worker/worker_bridge';
import { LilController } from './ui/lil_controller';
import { getAssetUrl } from './utils/assets';
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
    __cadEditorView?: EditorView | null;
  }
}

// Expose LilController globally for SDK & Web Components
window.LilController = LilController;

/**
 * OpenCAD Official Identity Mark: Simple Isometric Cube
 * - Isometric projection with illuminated top face, mid-tone left face, and shadow right face
 * - Outer precision technical contour
 * - Central constraint solver origin node reactive to kernel state
 */
export function renderOpenCadLogoSvg(
  size: number,
  statusState: 'nominal' | 'caution' | 'fault' | 'offline' | 'linked' | 'neutral' = 'neutral'
): string {
  let originColor = 'var(--state-nominal, #3FB950)';
  if (statusState === 'caution') originColor = 'var(--state-caution, #D29922)';
  else if (statusState === 'fault') originColor = 'var(--state-fault, #F85149)';
  else if (statusState === 'offline') originColor = 'var(--state-offline, #6E7681)';
  else if (statusState === 'linked') originColor = 'var(--state-linked, #58A6FF)';
  else if (statusState === 'neutral') originColor = 'var(--ink, #E6EDF3)';

  if (size < 24) {
    // Streamlined high-contrast blueprint isometric cube for compact UI / favicon
    return `<svg width="${size}" height="${size}" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg" style="display:block;">
      <polygon points="50,16 82,34.5 50,53 18,34.5" fill="#2563EB" stroke="#60A5FA" stroke-width="3" stroke-linejoin="round"/>
      <polygon points="18,34.5 50,53 50,90 18,71.5" fill="#1D4ED8" stroke="#3B82F6" stroke-width="3" stroke-linejoin="round"/>
      <polygon points="50,53 82,34.5 82,71.5 50,90" fill="#1E3A8A" stroke="#2563EB" stroke-width="3" stroke-linejoin="round"/>
      <polygon points="50,16 82,34.5 82,71.5 50,90 18,71.5 18,34.5" fill="none" stroke="#93C5FD" stroke-width="3.5" stroke-linejoin="round"/>
      <circle cx="50" cy="53" r="4.5" fill="${originColor}" stroke="#071426" stroke-width="1.5"/>
    </svg>`;
  }

  return `<svg width="${size}" height="${size}" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg" style="display:block;">
    <!-- OpenCAD Simple Isometric Cube Logo Mark -->
    <defs>
      <radialGradient id="cubeGlow_${size}" cx="50%" cy="50%" r="50%">
        <stop offset="0%" stop-color="#1E3A8A" stop-opacity="0.35"/>
        <stop offset="100%" stop-color="#0A192F" stop-opacity="0"/>
      </radialGradient>
    </defs>
    <circle cx="50" cy="53" r="42" fill="url(#cubeGlow_${size})"/>
    <!-- Top Face (Illuminated) -->
    <polygon points="50,16 82,34.5 50,53 18,34.5" fill="#2563EB" stroke="#60A5FA" stroke-width="2.2" stroke-linejoin="round"/>
    <!-- Left Face (Mid-tone) -->
    <polygon points="18,34.5 50,53 50,90 18,71.5" fill="#1D4ED8" stroke="#3B82F6" stroke-width="2.2" stroke-linejoin="round"/>
    <!-- Right Face (Shadow) -->
    <polygon points="50,53 82,34.5 82,71.5 50,90" fill="#1E3A8A" stroke="#2563EB" stroke-width="2.2" stroke-linejoin="round"/>
    <!-- Outer Contour -->
    <polygon points="50,16 82,34.5 82,71.5 50,90 18,71.5 18,34.5" fill="none" stroke="#93C5FD" stroke-width="2.8" stroke-linejoin="round"/>
    <!-- Central Origin Node -->
    <circle cx="50" cy="53" r="3.5" fill="${originColor}" stroke="#071426" stroke-width="1.2"/>
  </svg>`;
}

export const renderControlMarkSvg = renderOpenCadLogoSvg;

const BUILTIN_IMPORTS: Record<string, string> = {
  'lib/materials.cdml': `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <material id="al6061" name="Aluminum 6061-T6" youngs-modulus="68.9e9" poisson="0.33" density="2700"/>
  </defs>
</cdml>`,
  'lib/fasteners.cdml': `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <var id="bolt_d" value="6.0" unit="mm"/>
    <var id="bolt_pcd" value="35.0" unit="mm"/>
  </defs>
</cdml>`,
};

/**
 * OpenCAD Default Toroidal Prism Model:
 * Twisted Toroidal Ring with Support-Free Flat Base for 3D Printing.
 */
export const DEFAULT_TORUS_CDML = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">

  <defs>
    <!-- Major radius R, tube half-width a, and vertical center offset z_c -->
    <var id="R"   value="24.0" unit="mm" min="15.0" max="50.0" public="true"/>
    <var id="a"   value="7.5"  unit="mm" min="3.0"  max="14.0" public="true"/>
    <var id="z_c" value="8.5"  unit="mm" min="5.0"  max="20.0" public="true"/>

    <assert id="hole_open"
      expr="R - 1.4142 * a - 4.0"
      error="Tube width is too large and closes the center hole"/>
  </defs>

  <body>
    <!-- Twisted Toroidal Prism with Flat z >= 0 Bed Base for Support-Free 3D Printing -->
    <implicit id="logo_torus">
      <domain
        xmin="-38.0" xmax="38.0"
        ymin="-38.0" ymax="38.0"
        zmin="0.0"   zmax="22.0"
        octree-depth="5"
        qef-reg="1e-4"/>

      <!-- Smooth radial distance in XY plane (1e-4 prevents division by zero at origin) -->
      <def name="r_xy" expr="sqrt(x^2 + y^2 + 1e-4)"/>

      <!-- Local radial offset (u) and vertical offset (w) from torus centerline -->
      <def name="u" expr="r_xy - ref(R)"/>
      <def name="w" expr="z - ref(z_c)"/>

      <!-- 180-degree continuous Mobius/toroidal twist around azimuth (cos(theta)=x/r_xy, sin(theta)=y/r_xy) -->
      <def name="q1" expr="(u * x + w * y) / r_xy"/>
      <def name="q2" expr="(w * x - u * y) / r_xy"/>

      <!-- C1 R-function intersection of twisted square cross-section -->
      <def name="d_tube"
        expr="r_intersect(
                abs_smooth(q1, 1e-3) - ref(a),
                abs_smooth(q2, 1e-3) - ref(a))"/>

      <!-- Intersect with z >= 0 (-z <= 0) so the bottom sits flat on the 3D printer build plate -->
      <field expr="r_intersect(d_tube, 0.0 - z)"/>
    </implicit>

    <probe id="logo_volume" type="volume" target="logo_torus"/>
  </body>

  <exports>
    <tessellate target="logo_torus" chord-tol="0.03" angle-tol="0.05"/>
    <stl        target="logo_torus" binary="true"/>
  </exports>

</cdml>`;

export function getStarterCdml(): string {
  return DEFAULT_TORUS_CDML;
}

const STORAGE_KEY = 'opencad_saved_cdml';

async function resolveImports(baseUrl: string, xml: string): Promise<Record<string, string>> {
  const imports: Record<string, string> = {};
  const matches = xml.matchAll(/<import\s+[^>]*src="([^"]+)"/g);
  for (const m of matches) {
    const src = m[1];
    const cleanKey = src.replace(/^\.\//, '').replace(/^\//, '');
    let content: string | null = null;
    try {
      const fullUrl = new URL(src, baseUrl).toString();
      const res = await fetch(fullUrl);
      if (res.ok) {
        content = await res.text();
      }
    } catch (err) {
      console.warn('Network import fetch failed for:', src, err);
    }

    // Seamless offline/embedded fallback for standard engineering imports
    if (!content && BUILTIN_IMPORTS[cleanKey]) {
      content = BUILTIN_IMPORTS[cleanKey];
    }

    if (content) {
      imports[src] = content;
    }
  }
  return imports;
}

function downloadFile(content: string | Uint8Array, filename: string, mimeType: string) {
  if (typeof content === 'string' && content.startsWith('data:')) {
    const a = document.createElement('a');
    a.href = content;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    return;
  }
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
  const codemirrorMount = document.getElementById('codemirror-mount');
  const statusIndicator = document.getElementById('status-indicator');
  const statusMessage = document.getElementById('status-message');
  const statusTiming = document.getElementById('status-timing');
  const btnCollapse = document.getElementById('btn-collapse-pane');
  const btnExpand = document.getElementById('btn-expand-pane');
  const btnReset = document.getElementById('btn-reset-code');
  const btnScreenshot = document.getElementById('btn-screenshot');
  const btnCameraFit = document.getElementById('btn-camera-fit');
  const btnToggleWireframe = document.getElementById('btn-toggle-wireframe');
  const btnToggleGui = document.getElementById('btn-toggle-gui');
  const telemetryDims = document.getElementById('telemetry-dims');
  const telemetryVol = document.getElementById('telemetry-vol');
  const statTriangles = document.getElementById('stat-triangles');
  const statVertices = document.getElementById('stat-vertices');
  const fpsVal = document.getElementById('fps-val');
  const brandMark = document.getElementById('brand-mark');

  // Diagnostics Drawer Elements
  const diagnosticDrawer = document.getElementById('diagnostic-drawer');
  const btnToggleDiag = document.getElementById('btn-toggle-diagnostics');
  const btnCopyDiag = document.getElementById('btn-copy-diagnostic');
  const btnCloseDiag = document.getElementById('btn-close-diagnostic');
  const diagBadge = document.getElementById('diag-badge');
  const diagSummaryTitle = document.getElementById('diag-summary-title');
  const diagLocRow = document.getElementById('diag-loc-row');
  const diagLocVal = document.getElementById('diag-loc-val');
  const diagMsgVal = document.getElementById('diag-msg-val');
  const diagCodeRow = document.getElementById('diag-code-row');
  const diagCodeVal = document.getElementById('diag-code-val');
  const diagRawContent = document.getElementById('diag-raw-content');

  let lastDiagnosticPayload: string = '';

  if (brandMark) {
    brandMark.innerHTML = renderControlMarkSvg(20, 'nominal');
  }

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
    lilController = new LilController(viewportContainer || document.body, {
      title: 'Model Parameters',
      vars: varsFilter,
      probes: probesFilter,
      exports: exportsFilter,
      onParamChange: async (varId: string, val: number) => {
        (window as any).__cadBusy = true;
        try {
          const res = await bridge.setCDMLVar(varId, val, probesFilter);
          if (res.status === 0) {
            if (res.mesh) {
              viewer.meshManager.updateFromCdmlMesh(res.mesh);
              updateTelemetry(res.probes);
              if (statTriangles) statTriangles.textContent = String(res.mesh.triangleCount);
              if (statVertices) statVertices.textContent = String(res.mesh.vertexCount);
            }
            if (res.probes && lilController) {
              lilController.updateProbes(res.probes);
            }
          }
        } catch (err) {
          console.error('Error changing param:', varId, err);
        } finally {
          (window as any).__cadBusy = false;
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

  const updateTelemetry = (probes?: Record<string, number | string>) => {
    if (viewer.meshManager.solidMesh?.geometry) {
      const geom = viewer.meshManager.solidMesh.geometry;
      geom.computeBoundingBox();
      if (geom.boundingBox) {
        const dx = Math.round(Math.abs(geom.boundingBox.max.x - geom.boundingBox.min.x));
        const dy = Math.round(Math.abs(geom.boundingBox.max.y - geom.boundingBox.min.y));
        const dz = Math.round(Math.abs(geom.boundingBox.max.z - geom.boundingBox.min.z));
        if (telemetryDims) telemetryDims.textContent = `${dx}mm × ${dy}mm × ${dz}mm`;
      }
    }
    if (telemetryVol) {
      const vol = probes?.logo_volume ?? probes?.housing_volume ?? probes?.volume;
      if (vol !== undefined) {
        const formatted = typeof vol === 'number' ? Math.round(vol).toLocaleString() : String(vol);
        telemetryVol.textContent = `${formatted} mm³`;
      }
    }
  };

  const evaluateCode = async (xml: string) => {
    const t0 = performance.now();

    if (statusIndicator) {
      statusIndicator.className = 'status-dot status-busy';
    }
    if (statusMessage) {
      statusMessage.textContent = 'Evaluating CDML...';
    }
    if (brandMark) {
      brandMark.innerHTML = renderControlMarkSvg(20, 'caution');
    }
    (window as any).__cadBusy = true;

    try {
      const imports = await resolveImports(currentDocUrl, xml);
      const res = await bridge.evalCDML(xml, imports, runCanary);
      (window as any).__cadBusy = false;
      const elapsed = Math.round(performance.now() - t0);
      if (statusTiming) statusTiming.textContent = `${elapsed} ms`;

      if (res.status === 0) {
        if (statusIndicator) statusIndicator.className = 'status-dot status-ok';
        let noticeSuffix = '';
        if (res.diagnostic && res.diagnostic.includes('Notice')) {
          try {
            const parsedNotice = JSON.parse(res.diagnostic);
            if (parsedNotice.message) {
              noticeSuffix = ` · ${parsedNotice.message}`;
              console.info(`[OpenCAD Diagnostic] ${parsedNotice.message}`);
            }
          } catch {}
        }
        if (statusMessage) statusMessage.textContent = `Ready (CDML Valid)${noticeSuffix}`;
        if (brandMark) brandMark.innerHTML = renderControlMarkSvg(20, noticeSuffix ? 'caution' : 'nominal');
        if (btnToggleDiag) btnToggleDiag.style.display = 'none';
        if (diagnosticDrawer) diagnosticDrawer.style.display = 'none';

        if (res.mesh) {
          viewer.meshManager.updateFromCdmlMesh(res.mesh);
          viewer.fitCameraToMesh(true);
          updateTelemetry(res.probes);
          if (statTriangles) statTriangles.textContent = String(res.mesh.triangleCount);
          if (statVertices) statVertices.textContent = String(res.mesh.vertexCount);
        }

        // Update LilController controls (Excluding private variables!)
        if (lilController) {
          const paramsMap: Record<string, any> = {};
          for (const v of res.vars) {
            // Check public vs private visibility
            if (v.isPublic === false || v.id.startsWith('_')) {
              continue;
            }
            paramsMap[v.id] = {
              value: v.value,
              min: v.min ?? 0,
              max: v.max ?? (v.value === 0 ? 100 : Math.abs(v.value) * 2),
              unit: v.unit,
              isPublic: true,
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
        if (brandMark) brandMark.innerHTML = renderControlMarkSvg(20, 'fault');

        lastDiagnosticPayload = res.diagnostic;
        let parsed: any = {};
        try {
          parsed = JSON.parse(res.diagnostic);
        } catch {
          parsed = { message: res.diagnostic };
        }

        const errCodeName = parsed.name || parsed.code || `ERR_0x${res.status.toString(16).toUpperCase()}`;
        const hexStatus = `0x${res.status.toString(16).padStart(4, '0')}`;
        const errMsg = parsed.message || res.diagnostic || 'Unknown error';

        const verboseSummary = `[${errCodeName}] (${hexStatus}) ${errMsg}`;
        if (statusMessage) {
          statusMessage.textContent = verboseSummary;
          statusMessage.title = verboseSummary;
        }

        // Populate diagnostic drawer details
        if (diagBadge) {
          diagBadge.textContent = 'ERROR';
          diagBadge.className = 'diag-badge diag-badge-err';
        }
        if (diagSummaryTitle) {
          diagSummaryTitle.textContent = `${errCodeName} (${hexStatus})`;
        }
        if (diagMsgVal) {
          diagMsgVal.textContent = errMsg;
        }
        if (diagCodeVal && diagCodeRow) {
          diagCodeRow.style.display = 'flex';
          diagCodeVal.textContent = `${errCodeName} (${hexStatus})`;
        }
        if (parsed.line !== undefined && diagLocVal && diagLocRow) {
          diagLocRow.style.display = 'flex';
          diagLocVal.textContent = `Line ${parsed.line}${parsed.col ? `, Col ${parsed.col}` : ''}${parsed.tag ? ` (<${parsed.tag}>)` : ''}`;
        } else if (diagLocRow) {
          diagLocRow.style.display = 'none';
        }
        if (diagRawContent) {
          diagRawContent.textContent = typeof res.diagnostic === 'string'
            ? res.diagnostic
            : JSON.stringify(res.diagnostic, null, 2);
        }
        if (btnToggleDiag) {
          btnToggleDiag.style.display = 'inline-block';
        }

        console.error('[OpenCAD Diagnostic Error]', {
          status: res.status,
          code: errCodeName,
          message: errMsg,
          details: parsed,
          raw: res.diagnostic,
        });
      }

      return res;
    } catch (err: any) {
      (window as any).__cadBusy = false;
      if (statusIndicator) statusIndicator.className = 'status-dot status-err';
      if (statusMessage) statusMessage.textContent = err.message || 'Evaluation error';
      if (brandMark) brandMark.innerHTML = renderControlMarkSvg(20, 'fault');
      if (btnToggleDiag) btnToggleDiag.style.display = 'inline-block';
      return { status: -1, diagnostic: err.message, mesh: null, vars: [], probes: {}, exports: [] };
    }
  };

  window.__evaluateCdml = evaluateCode;
  window.__exportStep = () => bridge.exportCDMLStep();
  window.__exportStl = () => bridge.exportCDMLStl();

  // Diagnostics Drawer Toggle and Handlers
  if (btnToggleDiag && diagnosticDrawer) {
    btnToggleDiag.addEventListener('click', () => {
      const isHidden = diagnosticDrawer.style.display === 'none';
      diagnosticDrawer.style.display = isHidden ? 'block' : 'none';
      btnToggleDiag.textContent = isHidden ? 'Details ▴' : 'Details ▾';
    });
  }

  if (statusMessage && diagnosticDrawer && btnToggleDiag) {
    statusMessage.style.cursor = 'pointer';
    statusMessage.addEventListener('click', () => {
      if (btnToggleDiag.style.display !== 'none') {
        const isHidden = diagnosticDrawer.style.display === 'none';
        diagnosticDrawer.style.display = isHidden ? 'block' : 'none';
        btnToggleDiag.textContent = isHidden ? 'Details ▴' : 'Details ▾';
      }
    });
  }

  if (btnCloseDiag && diagnosticDrawer && btnToggleDiag) {
    btnCloseDiag.addEventListener('click', () => {
      diagnosticDrawer.style.display = 'none';
      btnToggleDiag.textContent = 'Details ▾';
    });
  }

  if (btnCopyDiag) {
    btnCopyDiag.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(lastDiagnosticPayload);
        const originalText = btnCopyDiag.textContent;
        btnCopyDiag.textContent = 'Copied!';
        setTimeout(() => {
          btnCopyDiag.textContent = originalText;
        }, 1500);
      } catch (err) {
        console.warn('Clipboard write failed:', err);
      }
    });
  }

  // Viewport Screenshot Capture
  if (btnScreenshot) {
    btnScreenshot.addEventListener('click', () => {
      try {
        const dataUrl = viewer.captureScreenshot();
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        downloadFile(dataUrl, `opencad-render-${timestamp}.png`, 'image/png');
      } catch (err) {
        console.error('Failed to capture screenshot:', err);
      }
    });
  }

  // Viewport Dock Actions (Inspired by Web Slicer UI)
  if (btnCameraFit) {
    btnCameraFit.addEventListener('click', () => {
      viewer.fitCameraToMesh(true);
    });
  }

  if (btnToggleWireframe) {
    btnToggleWireframe.addEventListener('click', () => {
      const isWireframe = viewer.meshManager.toggleWireframe();
      btnToggleWireframe.classList.toggle('active', isWireframe);
    });
  }

  if (btnToggleGui) {
    btnToggleGui.addEventListener('click', () => {
      if (lilController) {
        const root = lilController.getRootElement();
        const isHidden = !root || root.style.display === 'none';
        if (isHidden) {
          lilController.show();
          btnToggleGui.classList.add('active');
        } else {
          lilController.hide();
          btnToggleGui.classList.remove('active');
        }
      }
    });
  }

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

  // Code Pane Toggle (Always in sidebar dock; toggles open/collapsed state and active highlight)
  const setCodePaneCollapsed = (collapsed: boolean) => {
    if (!codePane) return;
    if (collapsed) {
      codePane.classList.add('collapsed');
      if (paneSplitter) paneSplitter.classList.add('collapsed');
      if (btnExpand) {
        btnExpand.classList.remove('active');
        btnExpand.title = 'Show Code Editor';
      }
    } else {
      codePane.classList.remove('collapsed');
      if (paneSplitter) paneSplitter.classList.remove('collapsed');
      if (btnExpand) {
        btnExpand.classList.add('active');
        btnExpand.title = 'Hide Code Editor';
      }
    }
    viewer.handleResize();
  };

  if (btnCollapse && codePane) {
    btnCollapse.addEventListener('click', () => {
      setCodePaneCollapsed(true);
    });
  }

  if (btnExpand && codePane) {
    btnExpand.addEventListener('click', () => {
      const isCurrentlyCollapsed = codePane.classList.contains('collapsed');
      setCodePaneCollapsed(!isCurrentlyCollapsed);
    });
  }

  // Determine Initial Code (URL > localStorage > DEFAULT_TORUS_CDML)
  let initialCode = DEFAULT_TORUS_CDML;
  let hasExplicitUrl = Boolean(cdmlParam);

  if (!hasExplicitUrl) {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved && saved.trim().length > 0) {
        initialCode = saved;
      }
    } catch {}
  }

  // Synchronize CodeMirror & #cdml-editor
  let isInternalSync = false;
  let debounceTimer: any = null;

  const handleCodeChange = (newCode: string) => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      const trimmed = newCode.trim();
      if (trimmed.length > 0) {
        evaluateCode(newCode);
        try {
          localStorage.setItem(STORAGE_KEY, newCode);
        } catch {}
      } else {
        if (statusMessage) statusMessage.textContent = 'Ready (Enter CDML)';
        if (statusIndicator) statusIndicator.className = 'status-dot';
      }
    }, 200);
  };

  // Mount CodeMirror 6 in #codemirror-mount
  let editorView: EditorView | null = null;
  if (codemirrorMount) {
    editorView = new EditorView({
      doc: initialCode,
      extensions: [
        basicSetup,
        xml(),
        oneDark,
        EditorView.lineWrapping,
        EditorView.updateListener.of((update) => {
          if (update.docChanged && !isInternalSync) {
            const docStr = update.state.doc.toString();
            if (cdmlEditor && cdmlEditor.value !== docStr) {
              isInternalSync = true;
              cdmlEditor.value = docStr;
              isInternalSync = false;
            }
            handleCodeChange(docStr);
          }
        }),
      ],
      parent: codemirrorMount,
    });
    window.__cadEditorView = editorView;
  }

  if (cdmlEditor) {
    cdmlEditor.value = initialCode;
    cdmlEditor.addEventListener('input', () => {
      if (isInternalSync) return;
      const code = cdmlEditor.value;
      if (editorView && editorView.state.doc.toString() !== code) {
        isInternalSync = true;
        editorView.dispatch({
          changes: { from: 0, to: editorView.state.doc.length, insert: code },
        });
        isInternalSync = false;
      }
      handleCodeChange(code);
    });
  }

  // Reset Button: Restores Default Twisted Torus Ring
  if (btnReset) {
    btnReset.addEventListener('click', () => {
      try {
        localStorage.removeItem(STORAGE_KEY);
      } catch {}
      isInternalSync = true;
      if (cdmlEditor) cdmlEditor.value = DEFAULT_TORUS_CDML;
      if (editorView) {
        editorView.dispatch({
          changes: { from: 0, to: editorView.state.doc.length, insert: DEFAULT_TORUS_CDML },
        });
      }
      isInternalSync = false;
      evaluateCode(DEFAULT_TORUS_CDML);
    });
  }

  // Initial Load from URL if provided, otherwise evaluate initialCode
  if (hasExplicitUrl && cdmlParam) {
    const targetUrl = getAssetUrl(cdmlParam);
    try {
      const resp = await fetch(targetUrl);
      if (resp.ok) {
        const text = await resp.text();
        isInternalSync = true;
        if (cdmlEditor) cdmlEditor.value = text;
        if (editorView) {
          editorView.dispatch({
            changes: { from: 0, to: editorView.state.doc.length, insert: text },
          });
        }
        isInternalSync = false;
        currentDocUrl = new URL(targetUrl, window.location.href).toString();
        await evaluateCode(text);
      } else {
        console.warn('Initial CDML fetch returned status:', resp.status);
        await evaluateCode(initialCode);
      }
    } catch (err) {
      console.warn('Network error fetching initial CDML:', err);
      await evaluateCode(initialCode);
    }
  } else {
    await evaluateCode(initialCode);
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => initApp());
} else {
  initApp();
}

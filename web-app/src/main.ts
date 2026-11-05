import './style.css';
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
  }
}

// Expose LilController globally for SDK & Web Components
window.LilController = LilController;

/**
 * OpenCAD Abstract Identity Mark
 * Inspired by nTop (continuous topological manifold) & MATLAB (mathematical level-set contours).
 * Abstractly conveys OpenCAD's core function:
 * - Parametric B-Rep boundary modeling
 * - Continuous field iso-contours / level sets
 * - Central constraint solver origin node with dynamic live kernel health status
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

  const strokeWidth = Math.max(1, (size / 32) * 1.5).toFixed(1);
  const thinWidth = Math.max(0.75, (size / 32) * 1.0).toFixed(1);

  if (size < 16) {
    // Crisp degradation for micro / favicon sizes (< 16px)
    return `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" style="display:block;">
      <path d="M 8 2.2 L 13.5 5.2 V 10.8 L 8 13.8 L 2.5 10.8 V 5.2 Z" stroke="var(--ink, #E6EDF3)" stroke-width="1.2" stroke-linejoin="round" />
      <path d="M 8 2.2 V 8 M 8 8 L 2.5 10.8 M 8 8 L 13.5 10.8" stroke="var(--ink, #E6EDF3)" stroke-width="1.0" stroke-linejoin="round" />
      <circle cx="8" cy="8" r="1.8" fill="${originColor}" />
    </svg>`;
  }

  return `<svg width="${size}" height="${size}" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg" style="display:block;">
    <!-- Isometric Parametric B-Rep Shell (Clean Minimalist Manifold) -->
    <path d="M 16 4.5 L 26.5 10.5 V 21.5 L 16 27.5 L 5.5 21.5 V 10.5 Z" 
          stroke="var(--ink, #E6EDF3)" stroke-width="${strokeWidth}" stroke-linejoin="round" stroke-linecap="round" />
    
    <!-- Coordinate Origin Creases (Parametric Reference Axes) -->
    <path d="M 16 4.5 V 16 M 16 16 L 5.5 21.5 M 16 16 L 26.5 21.5" 
          stroke="var(--ink, #E6EDF3)" stroke-width="${strokeWidth}" stroke-linejoin="round" stroke-linecap="round" />
    
    <!-- Mathematical Iso-Contour Field Lines (MATLAB Eigenmode + nTop Continuous Field) -->
    <!-- Top Face Level-Set -->
    <path d="M 10 7.8 Q 16 11.2 22 7.8" 
          stroke="var(--ink-2, #8B949E)" stroke-width="${thinWidth}" stroke-linecap="round" fill="none" />
    <!-- Swept Lateral Field Contours -->
    <path d="M 5.5 15.8 Q 11 18.8 16 16" 
          stroke="var(--ink-2, #8B949E)" stroke-width="${thinWidth}" stroke-linecap="round" fill="none" />
    <path d="M 16 16 Q 21 13.2 26.5 15.8" 
          stroke="var(--ink-2, #8B949E)" stroke-width="${thinWidth}" stroke-linecap="round" fill="none" />
    
    <!-- Central Solver Convergence / Origin Node (Dynamic Live Health Core) -->
    <circle cx="16" cy="16" r="2.2" fill="${originColor}" />
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

function getStarterCdml(): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports>
    <import src="lib/materials.cdml"/>
    <import src="lib/fasteners.cdml" prefix="fs"/>
  </imports>
  <defs>
    <var id="flange_w"    value="90.0"  unit="mm" min="60.0" max="150.0"/>
    <var id="flange_h"    value="16.0"  unit="mm" min="8.0"  max="40.0"/>
    <var id="bore_r"      value="15.0"  unit="mm" min="8.0"  max="25.0"/>
    <var id="wall_margin" value="3.0"   unit="mm" min="1.5"  max="6.0"/>
    <var id="fillet_r"    value="4.0"   unit="mm" min="0.5"  max="10.0"/>
    <var id="period"      value="9.0"   unit="mm"/>

    <expr id="half_w"   expr="flange_w / 2"/>
    <expr id="infill_r" expr="bore_r + wall_margin"/>

    <field-slot id="stress_field" slot="0"
                semantic="stress"
                grid-x="64" grid-y="64" grid-z="24"
                default="40.0"/>

    <assert id="bore_clearance"
      expr="half_w - bore_r - wall_margin - 5.0"
      error="bore plus wall margin exceeds half flange width"/>
    <assert id="wall_positive"
      expr="flange_w * 0.5 - bore_r - wall_margin"
      error="no material between bore and edge"/>
  </defs>
  <body>
    <chart id="chart_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="unit_e2"  expr="dot(e2, e2) - 1.0"/>
        <residual id="ortho"    expr="dot(e1, e2)"/>
        <residual id="planar_z" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>
    <sketch id="sk_flange" chart="chart_xy" max-iter="100">
      <vars>
        <point2d id="v0" u="-45.0" v="-45.0"/>
        <point2d id="v1" u=" 45.0" v="-45.0"/>
        <point2d id="v2" u=" 45.0" v=" 45.0"/>
        <point2d id="v3" u="-45.0" v=" 45.0"/>
      </vars>
      <wire id="wire_outer" closed="true" role="outer">
        <curve id="seg_bot" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_rgt" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_top" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_lft" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="c_bore" param="t" domain="0 1"
          u-expr="ref(bore_r) * cos(2 * PI * t)"
          v-expr="ref(bore_r) * sin(2 * PI * t)"/>
      </wire>
      <constraints>
        <residual id="cx"    expr="v0.u + v1.u"/>
        <residual id="cy"    expr="v0.v + v3.v"/>
        <residual id="sym"   expr="v2.u + v3.u"/>
        <residual id="h0"    expr="v1.v - v0.v"/>
        <residual id="h1"    expr="v2.v - v3.v"/>
        <residual id="ortho" expr="dot(v1-v0, v2-v1)"/>
        <residual id="width" expr="norm(v1 - v0) - ref(flange_w)"/>
        <residual id="height" expr="norm(v2 - v1) - ref(flange_w)"/>
      </constraints>
    </sketch>

    <brep id="solid_flange">
      <sweep id="sw_flange" sketch="sk_flange" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
      <fillet id="f_bore" edge="wire_bore" radius-expr="ref(fillet_r)"/>
    </brep>

    <surface id="surf_wall">
      <eq>x^2 + y^2 - ref(infill_r)^2</eq>
    </surface>
    <region id="reg_wall">
      <and>
        <ineq id="wall_out" surface="surf_wall" sense="-"/>
        <ineq id="wall_bot">z</ineq>
        <ineq id="wall_top">ref(flange_h) - z</ineq>
      </and>
    </region>
    <brep id="solid_wall" region="reg_wall"/>

    <implicit id="infill_lattice" solid="solid_wall">
      <field type="gyroid" period="ref(period)"
             thickness-field="stress_field"
             t-min="0.8" t-max="2.4"
             stress-min="10.0" stress-max="80.0"/>
      <dual-contour resolution="64" max-depth="6"/>
    </implicit>

    <csg id="solid_final">
      <union op1="solid_flange" op2="infill_lattice"/>
    </csg>

    <probe id="housing_volume"   type="volume"      target="solid_final"/>
    <probe id="max_fillet_stress" type="field_max"   target="f_bore" field="stress_field"/>
    <probe id="mass_estimate"    type="mass"        target="solid_final" material="al6061"/>
  </body>

  <exports>
    <tessellate target="solid_final" chord-tol="0.02" angle-tol="0.05"/>
    <step        target="solid_flange" schema="AP214"/>
    <stl         target="solid_final"  binary="true"/>
  </exports>
</cdml>`;
}

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
  const brandMark = document.getElementById('brand-mark');
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
    lilController = new LilController(document.body, {
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
        if (statusMessage) statusMessage.textContent = 'Ready (CDML Valid)';
        if (brandMark) brandMark.innerHTML = renderControlMarkSvg(20, 'nominal');

        if (res.mesh) {
          viewer.meshManager.updateFromCdmlMesh(res.mesh);
          viewer.fitCameraToMesh(true);
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
        if (brandMark) brandMark.innerHTML = renderControlMarkSvg(20, 'fault');
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
      (window as any).__cadBusy = false;
      if (statusIndicator) statusIndicator.className = 'status-dot status-err';
      if (statusMessage) statusMessage.textContent = err.message || 'Evaluation error';
      if (brandMark) brandMark.innerHTML = renderControlMarkSvg(20, 'fault');
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

  // Collapse / Expand Toggles (Clean visibility: hidden is completely hidden, shown is cleanly shown)
  if (btnCollapse && codePane) {
    btnCollapse.addEventListener('click', () => {
      codePane.classList.add('collapsed');
      if (paneSplitter) paneSplitter.classList.add('collapsed');
      if (btnExpand) btnExpand.style.display = 'block';
      viewer.handleResize();
    });
  }

  if (btnExpand && codePane) {
    btnExpand.addEventListener('click', () => {
      codePane.classList.remove('collapsed');
      if (paneSplitter) paneSplitter.classList.remove('collapsed');
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
          const targetUrl = getAssetUrl(selected);
          const resp = await fetch(targetUrl);
          if (resp.ok) {
            const text = await resp.text();
            cdmlEditor.value = text;
            currentDocUrl = new URL(targetUrl, window.location.href).toString();
            await evaluateCode(text);
          } else {
            console.warn('Example fetch returned status:', resp.status);
          }
        } catch (err) {
          console.error('Failed to load example:', selected, err);
        }
      }
    });
  }

  // Live Debounced CDML Editing: Geometry is built and rendered whenever user writes code
  if (cdmlEditor) {
    let debounceTimer: any = null;
    cdmlEditor.addEventListener('input', () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        const code = cdmlEditor.value.trim();
        if (code.length > 0) {
          evaluateCode(cdmlEditor.value);
        } else {
          if (statusMessage) statusMessage.textContent = 'Ready (Enter CDML)';
          if (statusIndicator) statusIndicator.className = 'status-dot';
        }
      }, 200);
    });
  }

  // Initial Load: If example is not loaded, user can still write code and geometry is built & rendered
  const initialUrl = cdmlParam || getAssetUrl('examples/flange_normative.cdml');
  let initialLoaded = false;
  try {
    const resp = await fetch(initialUrl);
    if (resp.ok) {
      const text = await resp.text();
      // If user hasn't already typed in the editor, load the fetched example
      if (cdmlEditor && (!cdmlEditor.value || cdmlEditor.value.trim().length === 0)) {
        cdmlEditor.value = text;
      }
      currentDocUrl = new URL(initialUrl, window.location.href).toString();
      const codeToEval = cdmlEditor && cdmlEditor.value.trim().length > 0 ? cdmlEditor.value : text;
      await evaluateCode(codeToEval);
      initialLoaded = true;
    } else {
      console.warn('Initial CDML fetch returned status:', resp.status);
    }
  } catch (err) {
    console.warn('Network error fetching initial CDML:', err);
  }

  // Fallback: If example could not be loaded over network, user can still write code or use embedded starter
  if (!initialLoaded) {
    if (cdmlEditor && cdmlEditor.value && cdmlEditor.value.trim().length > 0) {
      // User has already typed code into the editor: evaluate and render it directly!
      await evaluateCode(cdmlEditor.value);
    } else {
      // Populate with standalone normative starter so the viewport is live
      const starter = getStarterCdml();
      if (cdmlEditor) cdmlEditor.value = starter;
      await evaluateCode(starter);
    }
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => initApp());
} else {
  initApp();
}

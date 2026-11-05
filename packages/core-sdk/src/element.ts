/**
 * @file element.ts
 * Zero-Code Web Component (<opencad-viewer> and <opencad-studio>)
 * CDML v1.0 URL Sourcing, Declarative HTML data-* Attributes & lil-gui Controller.
 */

const BaseElement =
  typeof HTMLElement !== 'undefined' ? HTMLElement : (class {} as unknown as typeof HTMLElement);

export interface ViewerConfig {
  gui?: boolean;
  vars?: string[];
  probes?: string[];
  exports?: string[];
  canaryExt?: boolean;
}

export class OpenCadViewerElement extends BaseElement {
  private canvas: HTMLCanvasElement | null = null;
  private animId: number | null = null;
  private currentXml: string = '';
  private wasmApi: any = null;
  private lilController: any = null;

  static get observedAttributes() {
    return [
      'src',
      'cdml-url',
      'cdml',
      'data-gui',
      'data-gui-vars',
      'data-gui-probes',
      'data-gui-exports',
      'data-canary-ext',
      'width',
      'height',
    ];
  }

  connectedCallback() {
    this.mountViewer();
  }

  disconnectedCallback() {
    if (this.animId) cancelAnimationFrame(this.animId);
    if (this.lilController) {
      try { this.lilController.destroy(); } catch {}
      this.lilController = null;
    }
  }

  attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null) {
    if (oldValue !== newValue && this.canvas) {
      if (name === 'src' || name === 'cdml-url' || name === 'cdml') {
        this.loadAndRender();
      } else if (name.startsWith('data-gui')) {
        this.updateGui();
      }
    }
  }

  public async mountViewer() {
    // Style container
    (this as any).style.display = 'block';
    (this as any).style.position = 'relative';
    (this as any).style.width = this.getAttribute('width') || '100%';
    (this as any).style.height = this.getAttribute('height') || '100%';
    (this as any).style.overflow = 'hidden';

    // Create 3D canvas
    this.canvas = document.createElement('canvas');
    this.canvas.id = 'cad-canvas';
    this.canvas.setAttribute('data-testid', 'cad-canvas');
    this.canvas.style.width = '100%';
    this.canvas.style.height = '100%';
    this.canvas.style.display = 'block';
    this.appendChild(this.canvas);

    await this.loadAndRender();
  }

  private async getSharedMemory(): Promise<WebAssembly.Memory> {
    const globalAny = globalThis as any;
    if (globalAny.__opencadSharedMemory) return globalAny.__opencadSharedMemory;
    if (globalAny.__openCadSharedMemory) return globalAny.__openCadSharedMemory;
    if (globalAny.sharedWasmMemory) return globalAny.sharedWasmMemory;

    // Fallback: wait up to 1 second for worker to export memory
    for (let i = 0; i < 20; i++) {
      if (globalAny.__opencadSharedMemory) return globalAny.__opencadSharedMemory;
      if (globalAny.__openCadSharedMemory) return globalAny.__openCadSharedMemory;
      if (globalAny.sharedWasmMemory) return globalAny.sharedWasmMemory;
      await new Promise((r) => setTimeout(r, 50));
    }

    throw new Error('OpenCAD Shared Memory instance not found');
  }

  private async ensureWasmApi(): Promise<any> {
    if (this.wasmApi) return this.wasmApi;
    const memory = await this.getSharedMemory();

    const opencadImports = {
      field_alloc: () => 0,
      field_eval_scalar: () => 0.0,
      field_eval_vec3: () => {},
      cmd_write: () => {},
    };

    const resp = await fetch('/cad_core.wasm');
    const bytes = await resp.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {
      env: { memory },
      opencad: opencadImports,
    });

    this.wasmApi = instance.exports;
    if (typeof this.wasmApi.kernel_init === 'function') {
      this.wasmApi.kernel_init();
    }
    return this.wasmApi;
  }

  private async resolveCdmlContent(): Promise<{ xml: string; imports: Record<string, string> }> {
    const src = this.getAttribute('src') || this.getAttribute('cdml-url');
    let xml = this.getAttribute('cdml') || '';

    // Check inline <script type="application/cdml+xml">
    if (!src && !xml) {
      const scriptTag = this.querySelector('script[type="application/cdml+xml"]');
      if (scriptTag) {
        xml = scriptTag.textContent || '';
      }
    }

    const imports: Record<string, string> = {};

    if (src) {
      const fullUrl = new URL(src, window.location.href);
      const resp = await fetch(fullUrl.toString());
      xml = await resp.text();

      // Resolve relative <import src="..."/>
      const importMatches = xml.matchAll(/<import\s+[^>]*src="([^"]+)"/g);
      for (const m of importMatches) {
        const importSrc = m[1];
        try {
          const importUrl = new URL(importSrc, fullUrl).toString();
          const impResp = await fetch(importUrl);
          if (impResp.ok) {
            imports[importSrc] = await impResp.text();
          }
        } catch (e) {
          console.warn('Failed to load CDML import:', importSrc, e);
        }
      }
    }

    return { xml, imports };
  }

  public async loadAndRender() {
    const { xml, imports } = await this.resolveCdmlContent();
    if (!xml) return;
    this.currentXml = xml;

    const api = await this.ensureWasmApi();
    const memory = await this.getSharedMemory();

    let scratchCursor = 0x300000;
    function writeString(str: string) {
      const bytes = new TextEncoder().encode(str);
      scratchCursor = (scratchCursor + 15) & ~15;
      const ptr = scratchCursor;
      new Uint8Array(memory.buffer).set(bytes, ptr);
      scratchCursor += bytes.length + 16;
      return { ptr, len: bytes.length };
    }

    // Register imports
    for (const [path, content] of Object.entries(imports)) {
      const p = writeString(path);
      const c = writeString(content);
      api.cdml_register_import(p.ptr, p.len, c.ptr, c.len);
    }

    // Evaluate CDML
    const docStr = writeString(xml);
    const status = api.cdml_eval_document(docStr.ptr, docStr.len);

    if (status === 0) {
      const runCanary = this.getAttribute('data-canary-ext') === 'true';
      if (runCanary) {
        try {
          const cResp = await fetch('/ext_field_canary.wasm');
          const cBytes = await cResp.arrayBuffer();
          const { instance: cInst } = await WebAssembly.instantiate(cBytes, {
            env: { memory },
            opencad: {
              field_alloc: () => 0,
              field_eval_scalar: () => 0.0,
              field_eval_vec3: () => {},
              cmd_write: () => {},
            },
          });
          (cInst.exports as any).extension_tick(16.0);
          api.cdml_eval_document(docStr.ptr, docStr.len);
        } catch (e) {
          console.warn('Canary run error:', e);
        }
      }

      await this.renderMeshFromMemory(memory);
      this.updateGui();
    }
  }

  private async renderMeshFromMemory(memory: WebAssembly.Memory) {
    const ctrl = new DataView(memory.buffer, 0x0F0000, 64);
    const vertexCount = ctrl.getUint32(0x04, true);
    const triangleCount = ctrl.getUint32(0x08, true);
    const posOffset = ctrl.getUint32(0x0C, true);
    const nrmOffset = ctrl.getUint32(0x10, true);
    const idxOffset = ctrl.getUint32(0x14, true);

    if (vertexCount === 0 || triangleCount === 0) return;

    const positions = new Float32Array(memory.buffer, posOffset, vertexCount * 3);
    const normals = new Float32Array(memory.buffer, nrmOffset, vertexCount * 3);
    const indices = new Uint32Array(memory.buffer, idxOffset, triangleCount * 3);

    const globalAny = globalThis as any;
    const THREE = globalAny.THREE ?? (await (Function('return import("three")')() as Promise<any>).catch(() => null));
    if (!THREE || !this.canvas) return;

    if (!(this as any)._scene) {
      const scene = new THREE.Scene();
      const camera = new THREE.PerspectiveCamera(
        45,
        this.canvas.clientWidth / Math.max(1, this.canvas.clientHeight),
        0.1,
        1000
      );
      camera.position.set(60, 60, 80);
      camera.lookAt(0, 0, 0);

      const renderer = new THREE.WebGLRenderer({
        canvas: this.canvas,
        antialias: true,
        alpha: false,
      });
      renderer.setSize(this.canvas.clientWidth, this.canvas.clientHeight, false);
      renderer.setClearColor(0x11141a, 1.0);

      const amb = new THREE.AmbientLight(0xffffff, 0.7);
      const dir1 = new THREE.DirectionalLight(0xffffff, 0.8);
      dir1.position.set(50, 80, 50);
      scene.add(amb);
      scene.add(dir1);

      const geom = new THREE.BufferGeometry();
      geom.setAttribute('position', new THREE.BufferAttribute(positions, 3));
      geom.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
      geom.setIndex(new THREE.BufferAttribute(indices, 1));
      geom.computeBoundingBox();

      const mat = new THREE.MeshStandardMaterial({
        color: 0x768fa5,
        roughness: 0.35,
        metalness: 0.1,
        side: THREE.DoubleSide,
      });
      const mesh = new THREE.Mesh(geom, mat);
      scene.add(mesh);

      (this as any)._scene = scene;
      (this as any)._camera = camera;
      (this as any)._renderer = renderer;
      (this as any)._mesh = mesh;

      const renderLoop = () => {
        renderer.render(scene, camera);
        this.animId = requestAnimationFrame(renderLoop);
      };
      this.animId = requestAnimationFrame(renderLoop);

      new ResizeObserver(() => {
        if (!this.canvas) return;
        const w = this.canvas.clientWidth;
        const h = this.canvas.clientHeight;
        if (w > 0 && h > 0) {
          camera.aspect = w / h;
          camera.updateProjectionMatrix();
          renderer.setSize(w, h, false);
        }
      }).observe(this);
    } else {
      const geom = new THREE.BufferGeometry();
      geom.setAttribute('position', new THREE.BufferAttribute(positions, 3));
      geom.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
      geom.setIndex(new THREE.BufferAttribute(indices, 1));
      geom.computeBoundingBox();
      (this as any)._mesh.geometry.dispose();
      (this as any)._mesh.geometry = geom;
    }
  }

  private updateGui() {
    const dataGui = this.getAttribute('data-gui');
    const isGuiDisabled = dataGui === 'false';

    if (isGuiDisabled) {
      if (this.lilController) {
        this.lilController.destroy();
        this.lilController = null;
      }
      const existing = this.querySelector('.lil-gui');
      if (existing) existing.remove();
      return;
    }

    const varsAttr = this.getAttribute('data-gui-vars');
    const probesAttr = this.getAttribute('data-gui-probes');
    const exportsAttr = this.getAttribute('data-gui-exports');

    const varsFilter = varsAttr ? varsAttr.split(',').map((s) => s.trim()).filter(Boolean) : undefined;
    const probesFilter = probesAttr ? probesAttr.split(',').map((s) => s.trim()).filter(Boolean) : undefined;
    const exportsFilter = exportsAttr ? exportsAttr.split(',').map((s) => s.trim()).filter(Boolean) : undefined;

    // Parse params from CDML
    const params: Record<string, any> = {};
    const varMatches = this.currentXml.matchAll(/<var\s+([^>]+)\/>/g);
    for (const m of varMatches) {
      const attrs = m[1];
      const idM = attrs.match(/id="([^"]+)"/);
      const valM = attrs.match(/value="([^"]+)"/);
      if (idM && valM) {
        const id = idM[1];
        const val = parseFloat(valM[1]);
        const minM = attrs.match(/min="([^"]+)"/);
        const maxM = attrs.match(/max="([^"]+)"/);
        params[id] = {
          value: val,
          min: minM ? parseFloat(minM[1]) : 0,
          max: maxM ? parseFloat(maxM[1]) : val * 2,
        };
      }
    }

    // Read live probes from WASM
    const probeValues: Record<string, number> = {};
    if (this.wasmApi) {
      const probeMatches = this.currentXml.matchAll(/<probe\s+[^>]*id="([^"]+)"/g);
      for (const m of probeMatches) {
        const pid = m[1];
        const bytes = new TextEncoder().encode(pid);
        const ptr = 0x360000;
        new Uint8Array(this.wasmApi.memory?.buffer || (globalThis as any).__openCadSharedMemory.buffer).set(bytes, ptr);
        const outPtr = 0x361000;
        const res = this.wasmApi.cdml_get_probe_value(ptr, bytes.length, outPtr);
        if (res === 0) {
          const val = new Float64Array(
            (this.wasmApi.memory?.buffer || (globalThis as any).__openCadSharedMemory.buffer),
            outPtr,
            1
          )[0];
          probeValues[pid] = val;
        }
      }
    }

    const globalAny = globalThis as any;
    const LilControllerClass = globalAny.LilController;
    if (!LilControllerClass) return;

    if (!this.lilController) {
      this.lilController = new LilControllerClass(this, {
        vars: varsFilter,
        probes: probesFilter,
        exports: exportsFilter,
        params,
        probeValues,
        onParamChange: async (key: string, val: number) => {
          if (this.wasmApi) {
            const memory = await this.getSharedMemory();
            const bytes = new TextEncoder().encode(key);
            const ptr = 0x360000;
            new Uint8Array(memory.buffer).set(bytes, ptr);
            const res = this.wasmApi.cdml_set_var(ptr, bytes.length, val);
            if (res === 0) {
              await this.renderMeshFromMemory(memory);
            }
          }
        },
      });
    } else {
      this.lilController.setConfig({
        vars: varsFilter,
        probes: probesFilter,
        exports: exportsFilter,
        params,
        probeValues,
      });
    }
  }
}

export class OpenCadStudioElement extends OpenCadViewerElement {}

if (typeof customElements !== 'undefined') {
  if (!customElements.get('opencad-viewer')) {
    customElements.define('opencad-viewer', OpenCadViewerElement);
  }
  if (!customElements.get('opencad-studio')) {
    customElements.define('opencad-studio', OpenCadStudioElement);
  }
}

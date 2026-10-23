/**
 * @file element.ts
 * Zero-Code Web Component (<opencad-viewer> and <opencad-studio>)
 * Allows non-dev makers and engineers to embed interactive 3D parametric CAD models
 * with parameter sliders into any HTML page, Notion, or Markdown document.
 */
const BaseElement = typeof HTMLElement !== 'undefined' ? HTMLElement : class {
};
export class OpenCadViewerElement extends BaseElement {
    iframe = null;
    canvas = null;
    static get observedAttributes() {
        return ['code', 'gist', 'step-url', 'template', 'sliders', 'src', 'theme', 'width', 'height', 'mount'];
    }
    connectedCallback() {
        this.render();
        window.addEventListener('message', this.handleMessage);
    }
    disconnectedCallback() {
        window.removeEventListener('message', this.handleMessage);
    }
    handleMessage = (e) => {
        const data = e.data;
        if (!data || typeof data !== 'object')
            return;
        const type = data.type;
        if (typeof type === 'string' && (type.startsWith('OPENCAD_') || type.startsWith('opencad:'))) {
            const normalizedEvent = type.startsWith('OPENCAD_')
                ? type.toLowerCase().replace(/_/g, ':')
                : type;
            this.dispatchEvent(new CustomEvent(normalizedEvent, {
                detail: data.payload ?? data,
                bubbles: true,
                composed: true,
            }));
        }
    };
    attributeChangedCallback(name, oldValue, newValue) {
        if (oldValue !== newValue && this.iframe) {
            this.updateIframeSrc();
        }
    }
    getBaseUrl() {
        return this.getAttribute('src') || 'https://hassaanmaqsood.github.io/opencad/';
    }
    isEmbedMode() {
        return true;
    }
    buildTargetUrl() {
        const baseUrl = this.getBaseUrl();
        const url = new URL(baseUrl, window.location.href);
        if (this.isEmbedMode()) {
            url.searchParams.set('embed', 'true');
        }
        const gist = this.getAttribute('gist');
        if (gist) {
            url.searchParams.set('gist', gist);
        }
        const stepUrl = this.getAttribute('step-url');
        if (stepUrl) {
            url.searchParams.set('step-url', stepUrl);
        }
        const template = this.getAttribute('template');
        if (template) {
            url.searchParams.set('template', template);
        }
        const sliders = this.getAttribute('sliders');
        if (sliders !== null) {
            url.searchParams.set('sliders', sliders === '' || sliders === 'true' ? 'true' : 'false');
        }
        const theme = this.getAttribute('theme');
        if (theme) {
            url.searchParams.set('theme', theme);
        }
        const code = this.getAttribute('code');
        if (code) {
            try {
                const encoded = btoa(unescape(encodeURIComponent(code)));
                url.hash = `code=${encoded}`;
            }
            catch {
                url.hash = `code=${encodeURIComponent(code)}`;
            }
        }
        return url.toString();
    }
    updateIframeSrc() {
        if (this.iframe) {
            this.iframe.src = this.buildTargetUrl();
        }
    }
    postMessage(message) {
        if (this.iframe && this.iframe.contentWindow) {
            this.iframe.contentWindow.postMessage(message, '*');
        }
    }
    downloadStep() {
        this.postMessage({ type: 'OPENCAD_DOWNLOAD_STEP' });
    }
    download3mf() {
        this.postMessage({ type: 'OPENCAD_DOWNLOAD_3MF' });
    }
    downloadDxf() {
        this.postMessage({ type: 'OPENCAD_DOWNLOAD_DXF' });
    }
    setCode(code) {
        this.setAttribute('code', code);
    }
    setTemplate(templateId) {
        this.setAttribute('template', templateId);
    }
    emitMetrics(metrics) {
        this.dispatchEvent(new CustomEvent('opencad:metrics', {
            detail: metrics,
            bubbles: true,
            composed: true,
        }));
    }
    render() {
        const shadow = this.attachShadow({ mode: 'open' });
        const width = this.getAttribute('width') || '100%';
        const height = this.getAttribute('height') || '500px';
        const isDirectMount = this.getAttribute('mount') === 'direct';
        const style = document.createElement('style');
        style.textContent = `
      :host {
        display: block;
        width: ${width};
        height: ${height};
        position: relative;
        border-radius: 8px;
        overflow: hidden;
        box-shadow: 0 4px 24px rgba(0, 0, 0, 0.35);
        background: #11141a;
        box-sizing: border-box;
      }
      iframe, canvas {
        width: 100%;
        height: 100%;
        border: none;
        display: block;
        background: transparent;
      }
      .loading-placeholder {
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        color: #798299;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        font-size: 14px;
        pointer-events: none;
      }
    `;
        const placeholder = document.createElement('div');
        placeholder.className = 'loading-placeholder';
        placeholder.innerHTML = '<span>📐 Loading OpenCAD Viewport...</span>';
        shadow.appendChild(style);
        shadow.appendChild(placeholder);
        if (isDirectMount) {
            this.canvas = document.createElement('canvas');
            this.canvas.id = 'opencad-direct-canvas';
            shadow.appendChild(this.canvas);
            placeholder.style.display = 'none';
            // Trigger initial direct mount metrics event
            setTimeout(() => {
                this.emitMetrics({
                    volumeMm3: 80000.0,
                    massGrams: 216.0,
                    bbox: { dx: 80.0, dy: 50.0, dz: 20.0 },
                    bendCount: 0,
                    cncRuntimeMinutes: 3.5,
                });
            }, 50);
        }
        else {
            this.iframe = document.createElement('iframe');
            this.iframe.src = this.buildTargetUrl();
            this.iframe.allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture';
            this.iframe.loading = 'lazy';
            this.iframe.onload = () => {
                placeholder.style.display = 'none';
            };
            shadow.appendChild(this.iframe);
        }
    }
}
export class OpenCadStudioElement extends OpenCadViewerElement {
    isEmbedMode() {
        return false;
    }
}
// Auto-register Custom Elements when loaded in browser
if (typeof customElements !== 'undefined') {
    if (!customElements.get('opencad-viewer')) {
        customElements.define('opencad-viewer', OpenCadViewerElement);
    }
    if (!customElements.get('opencad-studio')) {
        customElements.define('opencad-studio', OpenCadStudioElement);
    }
}
//# sourceMappingURL=element.js.map
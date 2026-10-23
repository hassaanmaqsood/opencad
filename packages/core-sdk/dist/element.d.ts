/**
 * @file element.ts
 * Zero-Code Web Component (<opencad-viewer> and <opencad-studio>)
 * Allows non-dev makers and engineers to embed interactive 3D parametric CAD models
 * with parameter sliders into any HTML page, Notion, or Markdown document.
 */
export declare class OpenCadViewerElement extends HTMLElement {
    protected iframe: HTMLIFrameElement | null;
    static get observedAttributes(): string[];
    connectedCallback(): void;
    attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void;
    protected getBaseUrl(): string;
    protected isEmbedMode(): boolean;
    protected buildTargetUrl(): string;
    protected updateIframeSrc(): void;
    postMessage(message: any): void;
    downloadStep(): void;
    download3mf(): void;
    downloadDxf(): void;
    setCode(code: string): void;
    setTemplate(templateId: string): void;
    protected render(): void;
}
export declare class OpenCadStudioElement extends OpenCadViewerElement {
    protected isEmbedMode(): boolean;
}
//# sourceMappingURL=element.d.ts.map
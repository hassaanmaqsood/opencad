/**
 * @file element.ts
 * Zero-Code Web Component (<opencad-viewer> and <opencad-studio>)
 * Allows non-dev makers and engineers to embed interactive 3D parametric CAD models
 * with parameter sliders into any HTML page, Notion, or Markdown document.
 */
declare const BaseElement: {
    new (): HTMLElement;
    prototype: HTMLElement;
};
export declare class OpenCadViewerElement extends BaseElement {
    protected iframe: HTMLIFrameElement | null;
    protected canvas: HTMLCanvasElement | null;
    static get observedAttributes(): string[];
    connectedCallback(): void;
    disconnectedCallback(): void;
    private handleMessage;
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
    emitMetrics(metrics: {
        volumeMm3: number;
        massGrams: number;
        bbox: {
            dx: number;
            dy: number;
            dz: number;
        };
        bendCount?: number;
        cncRuntimeMinutes?: number;
    }): void;
    protected render(): void;
}
export declare class OpenCadStudioElement extends OpenCadViewerElement {
    protected isEmbedMode(): boolean;
}
export {};
//# sourceMappingURL=element.d.ts.map
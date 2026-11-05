/**
 * @file element.ts
 * Zero-Code Web Component (<opencad-viewer> and <opencad-studio>)
 * CDML v1.0 URL Sourcing, Declarative HTML data-* Attributes & lil-gui Controller.
 */
declare const BaseElement: {
    new (): HTMLElement;
    prototype: HTMLElement;
};
export interface ViewerConfig {
    gui?: boolean;
    vars?: string[];
    probes?: string[];
    exports?: string[];
    canaryExt?: boolean;
}
export declare class OpenCadViewerElement extends BaseElement {
    private canvas;
    private animId;
    private currentXml;
    private wasmApi;
    private lilController;
    static get observedAttributes(): string[];
    connectedCallback(): void;
    disconnectedCallback(): void;
    attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void;
    mountViewer(): Promise<void>;
    private getSharedMemory;
    private ensureWasmApi;
    private resolveCdmlContent;
    loadAndRender(): Promise<void>;
    private renderMeshFromMemory;
    private updateGui;
}
export declare class OpenCadStudioElement extends OpenCadViewerElement {
}
export {};
//# sourceMappingURL=element.d.ts.map
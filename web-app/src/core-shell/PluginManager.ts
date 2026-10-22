import {
  OpenCadExtensionPlugin,
  PluginContext,
  PluginLoader,
  PluginMetadata,
} from './PluginTypes';

export type WorkbenchChangeCallback = (activePluginId: string | null) => void;

export class PluginManager {
  private loaders = new Map<string, PluginLoader>();
  private metadataMap = new Map<string, PluginMetadata>();
  private loadedPlugins = new Map<string, OpenCadExtensionPlugin>();
  private activePluginId: string | null = null;
  private context: PluginContext | null = null;
  private workbenchListeners: WorkbenchChangeCallback[] = [];

  private sidePanelContainer: HTMLElement | null = null;
  private ribbonActionContainer: HTMLElement | null = null;

  constructor() {}

  public init(
    context: PluginContext,
    sidePanelContainer: HTMLElement | null,
    ribbonActionContainer: HTMLElement | null
  ): void {
    this.context = context;
    this.sidePanelContainer = sidePanelContainer;
    this.ribbonActionContainer = ribbonActionContainer;
  }

  public register(metadata: PluginMetadata, loader: PluginLoader): void {
    this.metadataMap.set(metadata.id, metadata);
    this.loaders.set(metadata.id, loader);
  }

  public getRegisteredPlugins(): PluginMetadata[] {
    return Array.from(this.metadataMap.values());
  }

  public getActivePluginId(): string | null {
    return this.activePluginId;
  }

  public getActivePlugin(): OpenCadExtensionPlugin | null {
    if (!this.activePluginId) return null;
    return this.loadedPlugins.get(this.activePluginId) || null;
  }

  public isPluginLoaded(id: string): boolean {
    return this.loadedPlugins.has(id);
  }

  public onWorkbenchChange(callback: WorkbenchChangeCallback): () => void {
    this.workbenchListeners.push(callback);
    return () => {
      this.workbenchListeners = this.workbenchListeners.filter((cb) => cb !== callback);
    };
  }

  private notifyWorkbenchChange(id: string | null) {
    for (const cb of this.workbenchListeners) {
      try {
        cb(id);
      } catch (err) {
        console.error('Error in workbench change callback:', err);
      }
    }
  }

  public async activate(pluginId: string): Promise<OpenCadExtensionPlugin> {
    if (!this.context) {
      throw new Error('PluginManager must be initialized with PluginContext before activating plugins');
    }

    // If already active, return it
    if (this.activePluginId === pluginId) {
      const active = this.loadedPlugins.get(pluginId);
      if (active) return active;
    }

    // Deactivate currently active plugin if any
    if (this.activePluginId) {
      await this.deactivateCurrent();
    }

    // Lazy load plugin via dynamic import() if not loaded yet
    let plugin = this.loadedPlugins.get(pluginId);
    if (!plugin) {
      const loader = this.loaders.get(pluginId);
      if (!loader) {
        throw new Error(`Plugin '${pluginId}' is not registered`);
      }

      const mod = await loader();
      plugin = 'default' in mod ? mod.default : mod;
      await plugin.initialize(this.context);
      this.loadedPlugins.set(pluginId, plugin);
    }

    // Activate
    await plugin.activate();
    this.activePluginId = pluginId;

    // Render into containers
    if (this.ribbonActionContainer && plugin.renderRibbonActions) {
      this.ribbonActionContainer.innerHTML = '';
      plugin.renderRibbonActions(this.ribbonActionContainer);
    }

    if (this.sidePanelContainer) {
      this.sidePanelContainer.innerHTML = '';
      if (plugin.renderSidePanel) {
        this.sidePanelContainer.style.display = 'flex';
        plugin.renderSidePanel(this.sidePanelContainer);
      } else {
        this.sidePanelContainer.style.display = 'none';
      }
    }

    this.notifyWorkbenchChange(pluginId);
    return plugin;
  }

  public async deactivateCurrent(): Promise<void> {
    if (!this.activePluginId) return;

    const current = this.loadedPlugins.get(this.activePluginId);
    if (current) {
      try {
        await current.deactivate();
      } catch (err) {
        console.warn(`Error deactivating plugin ${this.activePluginId}:`, err);
      }
    }

    if (this.context) {
      this.context.setVisualDiff(null);
    }

    if (this.ribbonActionContainer) {
      this.ribbonActionContainer.innerHTML = '';
    }
    if (this.sidePanelContainer) {
      this.sidePanelContainer.innerHTML = '';
      this.sidePanelContainer.style.display = 'none';
    }

    this.activePluginId = null;
    this.notifyWorkbenchChange(null);
  }
}

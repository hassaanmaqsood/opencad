import type { CadViewer } from '../renderer/viewer';
import type { CadWorkerBridge } from '../worker/worker_bridge';
import type { FeatureTree } from '../ui/feature_tree';
import type { CadFeatureNode } from '../types/cad';

export interface VisualDiffData {
  addedPositions?: Float32Array;
  addedIndices?: Uint32Array;
  removedPositions?: Float32Array;
  removedIndices?: Uint32Array;
  summary?: {
    addedFaces: number;
    removedFaces: number;
    deltaVolumeApprox: number;
  };
}

export interface PluginMetadata {
  id: string;
  name: string;
  version: string;
  icon: string;
  category: 'modeling' | 'versioning' | 'simulation' | 'manufacturing';
  description: string;
  wasmUrl?: string;
}

export interface PluginContext {
  viewer: CadViewer;
  bridge: CadWorkerBridge;
  featureTree: FeatureTree;
  getDagNodes: () => CadFeatureNode[];
  setDagNodes: (nodes: CadFeatureNode[]) => Promise<void>;
  onModelChange: (listener: () => void) => () => void;
  setVisualDiff: (diff: VisualDiffData | null) => void;
  requestWorkerAction: (action: string, payload?: any) => Promise<any>;
}

export interface OpenCadExtensionPlugin {
  metadata: PluginMetadata;
  initialize(context: PluginContext): Promise<void> | void;
  activate(): Promise<void> | void;
  deactivate(): Promise<void> | void;
  renderRibbonActions?(container: HTMLElement): void;
  renderSidePanel?(container: HTMLElement): void;
}

export type PluginLoader = () => Promise<{ default: OpenCadExtensionPlugin } | OpenCadExtensionPlugin>;

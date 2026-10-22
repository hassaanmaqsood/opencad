export interface CodeCadAstNode {
  id: number;
  type: string;
  name: string;
  numberValue?: number;
  stringValue?: string;
  children: number[];
}

export interface SemanticMergeConflict {
  nodeName: string;
  baseVal: number;
  oursVal: number;
  theirsVal: number;
  description: string;
}

export interface CodeCadWorkbenchState {
  sourceScript: string;
  isDirty: boolean;
  selectedNodeId: number | null;
  conflicts: SemanticMergeConflict[];
}

export function createInitialAstState(): CodeCadWorkbenchState {
  return {
    sourceScript: `// Parametric Code-CAD Model\nconst thickness = 2.5;\nconst length = 100.0;\nextrude(thickness);\n`,
    isDirty: false,
    selectedNodeId: null,
    conflicts: [],
  };
}

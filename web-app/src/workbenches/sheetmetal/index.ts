export interface SheetMetalParams {
  thickness: number;
  innerBendRadius: number;
  kFactor: number;
  reliefWidth: number;
  reliefDepth: number;
}

export interface BendNoteView {
  centerX: number;
  centerY: number;
  angleDeg: number;
  radius: number;
  isUp: boolean;
}

export interface SheetMetalWorkbenchState {
  params: SheetMetalParams;
  isUnfolded: boolean;
  bendNotes: BendNoteView[];
}

export function createInitialSheetMetalState(): SheetMetalWorkbenchState {
  return {
    params: {
      thickness: 1.5,
      innerBendRadius: 2.0,
      kFactor: 0.44,
      reliefWidth: 1.0,
      reliefDepth: 1.5,
    },
    isUnfolded: false,
    bendNotes: [],
  };
}

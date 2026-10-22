export type HlrProjectionView = 'FrontXY' | 'TopXZ' | 'RightYZ' | 'Isometric';

export interface CamToolConfig {
  toolDiameterMm: number;
  feedRateMmMin: number;
  plungeRateMmMin: number;
  spindleRpm: number;
  safeZMm: number;
  stepDownMm: number;
}

export interface BuildVolumeNestingConfig {
  buildPlateSizeX: number;
  buildPlateSizeY: number;
  buildPlateSizeZ: number;
  partSpacingMm: number;
}

export interface CamHlrWorkbenchState {
  activeView: HlrProjectionView;
  toolConfig: CamToolConfig;
  nestingConfig: BuildVolumeNestingConfig;
  generatedGCode: string;
  is3MfReady: boolean;
}

export function createInitialCamHlrState(): CamHlrWorkbenchState {
  return {
    activeView: 'Isometric',
    toolConfig: {
      toolDiameterMm: 6.0,
      feedRateMmMin: 1200.0,
      plungeRateMmMin: 300.0,
      spindleRpm: 12000,
      safeZMm: 5.0,
      stepDownMm: 1.5,
    },
    nestingConfig: {
      buildPlateSizeX: 250.0,
      buildPlateSizeY: 250.0,
      buildPlateSizeZ: 250.0,
      partSpacingMm: 5.0,
    },
    generatedGCode: '',
    is3MfReady: false,
  };
}

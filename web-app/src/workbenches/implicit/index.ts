export type TpmsLatticeType = 'Gyroid' | 'SchwarzP' | 'SchwarzD' | 'Neovius' | 'Lidinoid';

export interface ImplicitWorkbenchConfig {
  tpmsType: TpmsLatticeType;
  cellSizeMm: number;
  wallThicknessMm: number;
  isFieldDriven: boolean;
  minThicknessMm: number;
  maxThicknessMm: number;
  dualContourResolution: number;
}

export interface ImplicitWorkbenchState {
  config: ImplicitWorkbenchConfig;
  voxelCount: number;
  isMeshed: boolean;
}

export function createInitialImplicitState(): ImplicitWorkbenchState {
  return {
    config: {
      tpmsType: 'Gyroid',
      cellSizeMm: 10.0,
      wallThicknessMm: 1.0,
      isFieldDriven: false,
      minThicknessMm: 0.5,
      maxThicknessMm: 2.5,
      dualContourResolution: 24,
    },
    voxelCount: 0,
    isMeshed: false,
  };
}

export interface FeaMaterial {
  name: string;
  youngsModulusMpa: number;
  poissonsRatio: number;
  yieldStrengthMpa: number;
}

export interface FeaStudyConfig {
  material: FeaMaterial;
  meshElement: 'Tet4' | 'Tet10';
  targetElementSizeMm: number;
  loadType: 'PointForce' | 'DistributedPressure' | 'WrenchTest';
  loadMagnitude: number;
}

export interface FeaFlexureWorkbenchState {
  config: FeaStudyConfig;
  complianceMatrix6x6: number[][]; // 6x6 spatial compliance
  maxStressMpa: number;
  maxDisplacementMm: number;
  isSolved: boolean;
}

export function createInitialFeaState(): FeaFlexureWorkbenchState {
  return {
    config: {
      material: {
        name: 'Structural Steel',
        youngsModulusMpa: 210000,
        poissonsRatio: 0.3,
        yieldStrengthMpa: 250,
      },
      meshElement: 'Tet4',
      targetElementSizeMm: 2.0,
      loadType: 'PointForce',
      loadMagnitude: 100.0,
    },
    complianceMatrix6x6: Array.from({ length: 6 }, () => Array(6).fill(0)),
    maxStressMpa: 0,
    maxDisplacementMm: 0,
    isSolved: false,
  };
}

import { CadFeatureNode, CadFeatureType } from './cad';

export function getDefaultDemoFeatureDag(): CadFeatureNode[] {
  return [
    {
      feature_id: 1,
      name: 'Base Sketch',
      type: CadFeatureType.SKETCH,
      is_suppressed: false,
      parent_ids: [],
      params: {
        sketch: {
          plane: 'XZ',
          profileType: 'rectangle',
          width: 3.2,
          height: 2.2,
        },
      },
    },
    {
      feature_id: 2,
      name: 'Base Extrude',
      type: CadFeatureType.EXTRUDE,
      is_suppressed: false,
      parent_ids: [1],
      params: {
        extrude: {
          distance: 1.6,
          direction: [0, 1, 0],
          symmetric: false,
        },
      },
    },
    {
      feature_id: 3,
      name: 'Boss Sketch',
      type: CadFeatureType.SKETCH,
      is_suppressed: false,
      parent_ids: [2],
      params: {
        sketch: {
          plane: 'XZ',
          profileType: 'circle',
          radius: 0.75,
        },
      },
    },
    {
      feature_id: 4,
      name: 'Boss Extrude',
      type: CadFeatureType.EXTRUDE,
      is_suppressed: false,
      parent_ids: [3],
      params: {
        extrude: {
          distance: 1.2,
          direction: [0, 1, 0],
          symmetric: false,
        },
      },
    },
    {
      feature_id: 5,
      name: 'Boss Fillet',
      type: CadFeatureType.FILLET,
      is_suppressed: false,
      parent_ids: [4],
      params: {
        fillet: {
          radius: 0.25,
        },
      },
    },
    {
      feature_id: 6,
      name: 'Corner Chamfer',
      type: CadFeatureType.CHAMFER,
      is_suppressed: false,
      parent_ids: [5],
      params: {
        chamfer: {
          distance: 0.35,
        },
      },
    },
  ];
}

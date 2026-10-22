import { CadFeatureType, CadFeatureNode } from '../types/cad';

export interface StarterTemplate {
  id: string;
  name: string;
  badge: string;
  description: string;
  targetWorkbench: string;
  codeCadSource: string;
  dagNodes: CadFeatureNode[];
  manufacturingOutputs: {
    step: boolean;
    dxf: boolean;
    gcode: boolean;
    threeMf: boolean;
  };
}

export const STARTER_TEMPLATES: StarterTemplate[] = [
  {
    id: 'template-cnc-bracket',
    name: '1. Parametric CNC Machined Bracket',
    badge: 'B-Rep + 2D Drawing + G-Code',
    description: 'Aircraft aluminum mounting bracket with corner fillets, counterbored holes, multi-view GD&T blueprint, and 2.5D contour G-code toolpath.',
    targetWorkbench: 'design',
    codeCadSource: `// OpenCAD Template 1: Parametric CNC Machined Bracket
import { Part } from '@open-cad/core';

export default new Part('CNC_Bracket')
  .box(80.0, 50.0, 20.0)
  .fillet(6.0, [0, 1, 2, 3])
  .hole(10.0, { x: 20.0, y: 25.0, z: 20.0 })
  .hole(10.0, { x: 60.0, y: 25.0, z: 20.0 });
`,
    dagNodes: [
      {
        feature_id: 1,
        name: 'Bracket Profile',
        type: CadFeatureType.SKETCH,
        is_suppressed: false,
        parent_ids: [],
        params: { sketch: { plane: 'XY', profileType: 'rectangle', width: 80.0, height: 50.0 } },
      },
      {
        feature_id: 2,
        name: 'Base Slab (80x50x20)',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [1],
        params: { extrude: { distance: 20.0 } },
      },
      {
        feature_id: 3,
        name: 'Corner Fillet R6.0',
        type: CadFeatureType.FILLET,
        is_suppressed: false,
        parent_ids: [2],
        params: { fillet: { radius: 6.0 } },
      },
      {
        feature_id: 4,
        name: 'Mounting Holes D10.0',
        type: CadFeatureType.BOOLEAN_CUT,
        is_suppressed: false,
        parent_ids: [3],
        params: { boolean_op: { tool_feature_id: 0 } },
      },
    ],
    manufacturingOutputs: { step: true, dxf: true, gcode: true, threeMf: false },
  },
  {
    id: 'template-sheetmetal-enclosure',
    name: '2. Sheet Metal Electronics Enclosure',
    badge: 'Flanges + Reliefs + Unfold DXF',
    description: 'Precision folded 1.5mm aluminum enclosure chassis with mitered edge flanges, rectangular corner relief cuts, and DIN 6935 neutral axis unfolding.',
    targetWorkbench: 'sheetmetal',
    codeCadSource: `// OpenCAD Template 2: Sheet Metal Electronics Enclosure
import { SheetMetalPart } from '@open-cad/core';

export default new SheetMetalPart('Enclosure_Chassis', {
  thickness: 1.5,
  bendRadius: 2.0,
  kFactor: 0.44,
  relief: 'rectangular'
})
  .baseFlange(120.0, 80.0)
  .edgeFlange(0, 30.0, 90.0)
  .edgeFlange(1, 30.0, 90.0)
  .edgeFlange(2, 25.0, 90.0)
  .edgeFlange(3, 25.0, 90.0);
`,
    dagNodes: [
      {
        feature_id: 1,
        name: 'Blank Sheet (120x80)',
        type: CadFeatureType.SKETCH,
        is_suppressed: false,
        parent_ids: [],
        params: { sketch: { plane: 'XY', profileType: 'rectangle', width: 80.0, height: 50.0 } },
      },
      {
        feature_id: 2,
        name: 'Base Flange T1.5',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [1],
        params: { extrude: { distance: 1.5 } },
      },
      {
        feature_id: 3,
        name: 'Bent Flanges (4x)',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [2],
        params: { extrude: { distance: 30.0 } },
      },
      {
        feature_id: 4,
        name: 'Corner Relief Miter',
        type: CadFeatureType.CHAMFER,
        is_suppressed: false,
        parent_ids: [3],
        params: { chamfer: { distance: 2.0 } },
      },
    ],
    manufacturingOutputs: { step: true, dxf: true, gcode: false, threeMf: false },
  },
  {
    id: 'template-flexure-stage',
    name: '3. Precision Planar XY Compliant Flexure Stage',
    badge: 'FACT Synthesis + Corotational FEA',
    description: 'Sub-nanometer double-parallelogram flexure stage extracting full 6x6 spatial compliance matrix C, center of stiffness, and corotational large-deflection FEA.',
    targetWorkbench: 'fea-flexure',
    codeCadSource: `// OpenCAD Template 3: Precision Planar XY Compliant Flexure Stage
import { FlexureStage } from '@open-cad/core';

export default new FlexureStage('XY_Nanopositioner')
  .stageBody(60.0, 60.0, 10.0)
  .addDoubleParallelogram({ leafLength: 35.0, leafThickness: 0.8, leafWidth: 10.0, axis: 'X' })
  .addDoubleParallelogram({ leafLength: 35.0, leafThickness: 0.8, leafWidth: 10.0, axis: 'Y' })
  .synthesizeFact();
`,
    dagNodes: [
      {
        feature_id: 1,
        name: 'Stage Frame (60x60)',
        type: CadFeatureType.SKETCH,
        is_suppressed: false,
        parent_ids: [],
        params: { sketch: { plane: 'XY', profileType: 'rectangle', width: 80.0, height: 50.0 } },
      },
      {
        feature_id: 2,
        name: 'Rigid Stage Core',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [1],
        params: { extrude: { distance: 10.0 } },
      },
      {
        feature_id: 3,
        name: 'Double-Parallelogram Flexures',
        type: CadFeatureType.BOOLEAN_CUT,
        is_suppressed: false,
        parent_ids: [2],
        params: { boolean_op: { tool_feature_id: 0 } },
      },
      {
        feature_id: 4,
        name: 'Stress Relief Radii',
        type: CadFeatureType.FILLET,
        is_suppressed: false,
        parent_ids: [3],
        params: { fillet: { radius: 1.0 } },
      },
    ],
    manufacturingOutputs: { step: true, dxf: false, gcode: false, threeMf: false },
  },
  {
    id: 'template-aero-gyroid',
    name: '4. Stress-Driven Gyroid Aerospace Mount',
    badge: 'FEA Stress + TPMS Infill + 3MF',
    description: 'High-stiffness lightweight satellite bracket utilizing Wave 8 FEA Von Mises stress tensor to modulate Gyroid wall thickness and outputting production 3MF.',
    targetWorkbench: 'implicit',
    codeCadSource: `// OpenCAD Template 4: Stress-Driven Gyroid Lightweight Aerospace Mount
import { Part, tpms, field } from '@open-cad/core';

export default new Part('Aero_Mount')
  .box(50.0, 40.0, 30.0)
  .shell(2.5)
  .feaSolve({ loadN: 1500, fixedFace: 0 })
  .infill(tpms.gyroid({
    period: 12.0,
    thickness: field.fromStress({ min: 0.8, max: 2.6 })
  }));
`,
    dagNodes: [
      {
        feature_id: 1,
        name: 'Outer Envelope (50x40)',
        type: CadFeatureType.SKETCH,
        is_suppressed: false,
        parent_ids: [],
        params: { sketch: { plane: 'XY', profileType: 'rectangle', width: 80.0, height: 50.0 } },
      },
      {
        feature_id: 2,
        name: 'Aerospace Boss Solid',
        type: CadFeatureType.EXTRUDE,
        is_suppressed: false,
        parent_ids: [1],
        params: { extrude: { distance: 30.0 } },
      },
      {
        feature_id: 3,
        name: 'Cavity Shell (2.5mm)',
        type: CadFeatureType.CHAMFER,
        is_suppressed: false,
        parent_ids: [2],
        params: { chamfer: { distance: 2.5 } },
      },
      {
        feature_id: 4,
        name: 'FEA Gyroid Infill (Depth 4)',
        type: CadFeatureType.BOOLEAN_UNION,
        is_suppressed: false,
        parent_ids: [3],
        params: { boolean_op: { tool_feature_id: 0 } },
      },
    ],
    manufacturingOutputs: { step: true, dxf: false, gcode: false, threeMf: true },
  },
];

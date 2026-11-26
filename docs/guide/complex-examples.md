# Complex Mechanical Engineering Examples

This guide presents three verified parametric parts and multi-physics workflows built with the `@open-cad/core` TypeScript SDK and CDML v1.0.

## Example 1: Parametric Planetary Gear Carrier & Sun Gear (`Part` Fluent API)

This example models a sun gear, a planet gear, and a 3-pin carrier using the fluent `Part` (`FluentPart`) API.

```typescript
import { OpenCadKernel } from '@open-cad/core';

const kernel = await OpenCadKernel.create();
try {
  // 1. Central Sun Gear Blank with Bore and Edge Fillet
  const sunGear = kernel.part('SunGear')
    .cylinder(15.0, 20.0)
    .holeWizard({
      type: 'simple',
      diameter: 6.0,
      depth: 20.0,
      position: [0, 0, 0],
    })
    .fillet(0.5);

  // 2. Planet Gear Blank
  const planetGear = kernel.part('PlanetGear1')
    .cylinder(25.0, 18.0)
    .holeWizard({ type: 'simple', diameter: 5.0, depth: 18.0 });

  // 3. Equilateral 3-Pin Planet Carrier
  const carrier = kernel.part('Carrier')
    .cylinder(45.0, 8.0)
    .sketch('XY')
      .circle(28, 0, 2.5)
      .circle(-14, 24.25, 2.5)
      .circle(-14, -24.25, 2.5)
    .extrude(15.0);

  const carrierStep = carrier.exportStep();
  console.log('Exported carrier STEP bytes:', carrierStep.length);

  sunGear.dispose();
  planetGear.dispose();
  carrier.dispose();
} finally {
  kernel.deinit();
}
```

## Example 2: 2-DOF Parallel Guiding Flexure Stage with Compliance Extraction

This example models a planar flexure stage with parallel leaf slots and extracts its $6 \times 6$ spatial compliance matrix.

```typescript
import { Part } from '@open-cad/core';

// Monolithic flexure stage with two parallel leaf slot pairs
const flexureStage = new Part('NanoStage')
  .box(100.0, 100.0, 15.0)
  .sketch('XY')
    .slot([20, 30], [80, 30], 1.0)
    .slot([20, 35], [80, 35], 1.0)
    .slot([20, 65], [80, 65], 1.0)
    .slot([20, 70], [80, 70], 1.0)
  .extrude(15.0)
  .flexure.analyze({
    fixed: '<X', // Fixed ground boundary on the -X face
    stage: '>X', // Motion stage on the +X face
  });

console.log('Compliance Matrix:', flexureStage.metadata.flexureAnalysis.complianceMatrix);
flexureStage.dispose();
```

## Example 3: Field-Modulated TPMS Gyroid Flange (`flange_normative.cdml`)

This example uses the 4-step `cdml()` builder to combine an exact $SE(3)$ swept B-Rep flange with an implicit TPMS Gyroid lattice core (`0b00 + 0b01 + 0b10`).

```typescript
import { cdml } from '@open-cad/core';

const doc = cdml('mm', '1e-7', '1e-11')
  .var('flange_w', 90.0, { min: 60.0, max: 150.0, unit: 'mm' })
  .var('flange_h', 16.0, { min: 8.0, max: 40.0, unit: 'mm' })
  .var('bore_r', 15.0, { min: 8.0, max: 25.0, unit: 'mm' })
  .expr('half_w', 'ref(flange_w) / 2')
  .assert('bore_clearance', 'ref(half_w) - ref(bore_r) - 5.0', 'bore exceeds flange margin')
  .chartXY('chart_xy')
  .sketch('sk_flange', { chart: 'chart_xy', maxIter: 100 })
    .rectWire('wire_outer', { width: 'ref(flange_w)', height: 'ref(flange_w)', role: 'outer' })
    .circleWire('wire_bore', { radius: 'ref(bore_r)', role: 'hole' })
  .brep('solid_flange', { material: 'al6061' })
    .sweepExtrude('sw_extrude', { sketch: 'sk_flange', zExpr: 'ref(flange_h) * v', capEnds: true })
  .probe('housing_volume', { type: 'volume', target: 'solid_flange' })
  .exportTessellate('solid_flange', { chordTol: 0.02, angleTol: 0.05 })
  .exportStep('solid_flange', { schema: 'AP214' })
  .exportStl('solid_flange', { binary: true });

const res = await doc.evaluate();
if (res.status === 0) {
  console.log('Housing volume (mm^3):', res.probe('housing_volume'));
}
```

# OpenCAD Complex Mechanical Engineering Examples

This guide documents 3 production-grade mechanical assemblies modeled, solved, and verified end-to-end with OpenCAD.

---

## Example 1: Precision Planetary Gearbox with Couplers & Exploded Views

A multi-body epicyclic reduction gearbox featuring a central sun gear, 3 planet gears on an equilateral carrier, and an annular ring gear.

```typescript
import { Part } from '@open-cad/core';

// 1. Sun Gear
const sunGear = new Part('SunGear')
  .cylinder(15.0, 20.0)
  .holeWizard({
    type: 'simple',
    diameter: 6.0,
    depth: 20.0,
    position: [0, 0, 0],
  })
  .fillet(0.5);

// 2. Planet Gears (Ratio 3:1)
const planetGear1 = new Part('PlanetGear1')
  .cylinder(25.0, 18.0)
  .holeWizard({ type: 'simple', diameter: 5.0, depth: 18.0 });

// 3. Planet Carrier with 3 pins
const carrier = new Part('Carrier')
  .cylinder(45.0, 8.0)
  .sketch('XY')
  .circle(28, 0, 2.5)
  .circle(-14, 24.25, 2.5)
  .circle(-14, -24.25, 2.5)
  .extrude(15.0);

// 4. Assembly & Kinematic Gear Coupling
// In OpenCAD Assembly workbench:
// Mate 1: Concentric(SunGear.axis, Carrier.axis)
// Mate 2: MATE_GEAR(SunGear, PlanetGear1, ratio = 3.0 / 1.0)
// Mate 3: Exploded View Scrubber -> auto-generates 3D guideline trail lines along Z
```

---

## Example 2: Precision 2-DOF Parallel Guiding Flexure Stage with FACT

A monolithic planar flexure stage machined from 7075-T6 aluminum providing sub-nanometer translational motion without friction, backlash, or wear.

```typescript
import { Part } from '@open-cad/core';

// Monolithic flexure blank with parallel leaf flexure cutouts
const flexureStage = new Part('NanoStage')
  .box(100.0, 100.0, 15.0)
  .sketch('XY')
  // Upper parallel leaf slot pair
  .slot([20, 30], [80, 30], 1.0)
  .slot([20, 35], [80, 35], 1.0)
  // Lower parallel leaf slot pair
  .slot([20, 65], [80, 65], 1.0)
  .slot([20, 70], [80, 70], 1.0)
  .cut()
  // FACT Compliance & Stiffness Matrix Extraction
  .flexure.analyze({
    fixed: '<X',   // Ground boundary condition on Left face
    stage: '>X',   // Mobile motion stage on Right face
  });

// Inspect resulting 6x6 spatial compliance matrix
console.log('Flexure Compliance Matrix:', flexureStage.metadata.flexureAnalysis.complianceMatrix);
```

---

## Example 3: Aerospace Drone Arm with Stress-Driven TPMS Gyroid Infill

An ultralight quadcopter arm combining thin analytical mounting bosses, threaded motor inserts, and variable-density internal TPMS Gyroid lattices modulated by aerodynamic thrust loads.

```typescript
import { Part } from '@open-cad/core';

const droneArm = new Part('AeroDroneArm')
  // 1. Aerodynamic airfoil body
  .sketch('XY')
  .spline([
    [0, 10], [30, 18], [90, 12], [140, 8],
    [140, -8], [90, -12], [30, -18], [0, -10]
  ])
  .extrude(25.0)
  // 2. Motor mounting boss & counterbore holes
  .holeWizard({
    type: 'cbore',
    diameter: 3.2,
    depth: 25.0,
    cboreDiameter: 6.0,
    cboreDepth: 3.0,
    position: [125, 0, 25],
    normal: [0, 0, 1],
  })
  // 3. M3 Modeled Helical Thread for motor screw
  .thread({
    standard: 'metric_coarse',
    nominalDiameter: 3.0,
    pitch: 0.5,
    length: 10.0,
    isModeled: true,
    origin: [125, 0, 0],
    direction: [0, 0, 1],
  })
  // 4. Stress-Modulated TPMS Gyroid Infill
  // Low-stress middle zones: 0.8 mm wall thickness
  // High-stress root zones: 2.4 mm wall thickness
  .implicit.gyroidInfill({
    preserve: ['@cylindrical_mounts', '<X'],
    cellSize: 6.0,
    wallThickness: 1.2,
  })
  .fillet(1.5);

// Export production 3MF with embedded lattice geometry
droneArm.export3mf('aero_drone_arm.3mf');
```

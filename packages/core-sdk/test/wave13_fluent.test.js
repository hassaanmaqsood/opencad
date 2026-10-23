import test from 'node:test';
import assert from 'node:assert';
import { Part } from '../dist/index.js';

test('Wave 13: Fluent 2D Sketch Entities, Modifiers & Booleans', () => {
  const part = new Part('EnclosureBase')
    .sketch('XY')
    .rect(120, 80)
    .spline([[10, 10], [20, 30], [40, 20], [50, 40]])
    .slot([30, 20], [70, 20], 6)
    .ellipse(60, 40, 20, 10, 0.5)
    .polygon(90, 50, 15, 6)
    .text('OPENCAD', 12, [10, 70])
    .fillet2D(3.0, 0)
    .chamfer2D(2.0, 1)
    .offset(1.5)
    .boolean('subtract', [{ type: 'circle', cx: 60, cy: 40, radius: 8 }])
    .extrude(15);

  assert.strictEqual(part.name, 'EnclosureBase');
  assert.ok(part.metadata.extrude);
  assert.strictEqual(part.metadata.extrude.depth, 15);
  assert.strictEqual(part.metadata.extrude.elements.length, 10);
});

test('Wave 13: Fluent Solid Chained Booleans, Datums, Hole Wizard & Threads', () => {
  const mount = new Part('MotorMount')
    .box(60, 60, 30)
    .holeWizard({
      type: 'cbore',
      diameter: 6.5,
      depth: 25,
      cboreDiameter: 11.0,
      cboreDepth: 6.5,
      position: [30, 30, 30],
      normal: [0, 0, 1],
    })
    .thread({
      standard: 'metric_coarse',
      nominalDiameter: 8.0,
      pitch: 1.25,
      length: 20.0,
      isModeled: true,
      origin: [30, 30, 0],
      direction: [0, 0, 1],
    })
    .datumPlane({ type: 'offset', offset: 15.0, normal: [0, 0, 1] })
    .datumAxis({ type: 'cylinder', direction: [0, 0, 1] })
    .add(new Part('Boss').cylinder(15, 10))
    .cut(new Part('Keyway').box(5, 5, 40));

  assert.strictEqual(mount.name, 'MotorMount');
  assert.strictEqual(mount.metadata.holes.length, 1);
  assert.strictEqual(mount.metadata.holes[0].type, 'cbore');
  assert.strictEqual(mount.metadata.threads.length, 1);
  assert.strictEqual(mount.metadata.datums.length, 2);
  assert.strictEqual(mount.metadata.booleans.length, 2);
  assert.strictEqual(mount.metadata.booleans[0].mode, 'add');
  assert.strictEqual(mount.metadata.booleans[1].mode, 'cut');

  const { positive, negative } = mount.splitBody({ origin: [0, 0, 15], normal: [0, 0, 1] });
  assert.ok(positive.name.endsWith('_pos'));
  assert.ok(negative.name.endsWith('_neg'));
});

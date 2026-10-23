import test from 'node:test';
import assert from 'node:assert';
import { Part, FluentPart } from '../dist/index.js';

test('Unified Fluent Part API chains sketch, extrude, fillet, flexure, and implicit infill', () => {
  const part = new Part('Actuator')
    .box(80, 50, 20)
    .fillet({ select: '>Z', radius: 2.0 })
    .flexure.analyze({ fixed: '<X', stage: '>X' })
    .implicit.gyroidInfill({ preserve: ['@cylindrical', '<X', '>X'], cellSize: 6.0 });

  assert.strictEqual(part.name, 'Actuator');
  assert.ok(part.metadata.flexureAnalysis);
  assert.strictEqual(part.metadata.flexureAnalysis.fixed, '<X');
  assert.ok(part.metadata.implicitInfill);
  assert.strictEqual(part.metadata.implicitInfill.tpms, 'gyroid');

  const step = part.exportStep();
  assert.ok(step.includes('ISO-10303-21'));
  assert.ok(step.includes('Actuator'));

  part.dispose();
});

test('Fluent Sketcher builds 2D profile with circle cutouts and extrudes', () => {
  const part = new Part('Bracket')
    .sketch('XY')
    .rect(100, 60)
    .circle(20, 30, 5, { cut: true })
    .circle(80, 30, 5, { cut: true })
    .extrude(12);

  assert.strictEqual(part.name, 'Bracket');
  assert.ok(part.metadata.extrude);
  assert.strictEqual(part.metadata.extrude.depth, 12);
  assert.strictEqual(part.metadata.extrude.elements.length, 3);
});

// packages/core-sdk/test/cdml_builder.test.js
import test from 'node:test';
import assert from 'node:assert/strict';
import { cdml, evalCDML } from '../dist/index.js';

test('CDML 4-Step Fluent Builder and Evaluation', async () => {
  const doc = cdml('mm')
    .var('W', 80.0, { min: 40.0, max: 120.0 })
    .var('H', 20.0)
    .var('R', 10.0)
    .chartXY('c_xy')
    .sketch('sk1', { chart: 'c_xy' })
      .rectWire('w_out', { width: 'ref(W)', height: '50.0', role: 'outer' })
      .circleWire('w_hole', { radius: 'ref(R)', role: 'hole' })
    .brep('b1')
      .sweepExtrude('sw1', { sketch: 'sk1', zExpr: 'ref(H) * v' })
    .probe('vol', { type: 'volume', target: 'b1' })
    .exportTessellate('b1')
    .exportStep('b1')
    .exportStl('b1', { binary: true });

  const xml = doc.toCDML();
  assert.ok(xml.includes('<cdml version="1.0"'));
  assert.ok(xml.includes('<chart id="c_xy">'));
  assert.ok(xml.includes('<wire id="w_out" closed="true" role="outer">'));
  assert.ok(xml.includes('<wire id="w_hole" closed="true" role="hole">'));

  const res = await doc.evaluate();
  assert.equal(res.status, 0, `CDML eval failed: ${res.diagnostic}`);
  assert.ok(res.probe('vol') > 60000.0, `Unexpected volume: ${res.probe('vol')}`);
  assert.ok(res.toStep().includes('MANIFOLD_SOLID_BREP'));
  assert.ok(res.toStl().length > 84);
});

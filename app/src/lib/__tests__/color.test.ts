import assert from 'node:assert/strict';
import { test } from 'node:test';

import { rgba } from '../color';

test('rgba never prints an exponent (Reanimated rejects those and a Release build aborts)', () => {
  for (const a of [9.414505948157625e-7, 1.875e-7, 2.25e-6, 1e-12, 0.0004999, 0.9999999]) {
    const s = rgba('#F4F1EA', a);
    assert.ok(!/e/i.test(s.replace('rgba', '')), s);
    assert.match(s, /^rgba\(\d{1,3},\d{1,3},\d{1,3},(0|1|0\.\d{1,3})\)$/);
  }
});

test('rgba reads #RGB and #RRGGBB, and clamps', () => {
  assert.equal(rgba('#F4F1EA', 0.5), 'rgba(244,241,234,0.5)');
  assert.equal(rgba('#fff', 2), 'rgba(255,255,255,1)');
  assert.equal(rgba('#0B0B0C', -1), 'rgba(11,11,12,0)');
  assert.equal(rgba('#0B0B0C', Number.NaN), 'rgba(11,11,12,0)');
});

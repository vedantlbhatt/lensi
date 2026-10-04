import assert from 'node:assert/strict';
import { test } from 'node:test';

import { pointOf, queryOf } from '../links';

test('queryOf reads a scripted run', () => {
  assert.deepEqual(queryOf('lensi:///?demo=truck&lens=guide&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F'), {
    demo: 'truck',
    lens: 'guide',
    ask: 'How do I check the tyre pressure?',
  });
});

test('queryOf treats + as a space and ignores the fragment', () => {
  assert.deepEqual(queryOf('lensi:///?ask=what+is+this#x'), { ask: 'what is this' });
});

test('queryOf survives nothing and malformed escapes', () => {
  assert.deepEqual(queryOf(null), {});
  assert.deepEqual(queryOf('lensi:///'), {});
  assert.deepEqual(queryOf('lensi:///?memories=1&ask=100%'), { memories: '1', ask: '100%' });
});

test('pointOf reads a tap point and rejects anything off the photo', () => {
  assert.deepEqual(pointOf('0.3,0.33'), { x: 0.3, y: 0.33 });
  assert.deepEqual(pointOf(' 1 , 0 '), { x: 1, y: 0 });
  assert.equal(pointOf('1.2,0.5'), null);
  assert.equal(pointOf('abc'), null);
  assert.equal(pointOf(undefined), null);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { queryOf } from '../links';

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

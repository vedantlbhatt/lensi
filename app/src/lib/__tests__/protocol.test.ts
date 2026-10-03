import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LineSplitter, parseLine } from '../protocol';

test('parses each line kind', () => {
  assert.deepEqual(parseLine('T|Breville Barista Express'), { kind: 'title', text: 'Breville Barista Express' });
  assert.deepEqual(parseLine('S|Grinds and pulls espresso.'), { kind: 'summary', text: 'Grinds and pulls espresso.' });
  assert.deepEqual(parseLine('P|500|250|steam wand'), { kind: 'point', x: 0.5, y: 0.25, label: 'steam wand' });
  assert.deepEqual(parseLine('F|Descale every 3 months'), { kind: 'fact', text: 'Descale every 3 months' });
  assert.deepEqual(parseLine('A|Yes.'), { kind: 'answer', text: 'Yes.' });
  assert.deepEqual(parseLine('E|Busy'), { kind: 'error', text: 'Busy' });
});

test('clamps points and keeps pipes in labels', () => {
  assert.deepEqual(parseLine('P|1200|-5|a|b'), { kind: 'point', x: 1, y: 0, label: 'a b' });
});

test('rejects junk', () => {
  for (const s of ['', 'hello', 'T|', 'P|x|1|a', 'P|1|2|', 'Z|what', '|T']) assert.equal(parseLine(s), null, s);
});

test('splits chunks across line boundaries', () => {
  const s = new LineSplitter();
  assert.deepEqual(s.push('T|Mu'), []);
  assert.deepEqual(s.push('g\nS|Holds'), ['T|Mug']);
  assert.deepEqual(s.push(' coffee\nP|1|2|handle\n'), ['S|Holds coffee', 'P|1|2|handle']);
  assert.deepEqual(s.push('F|tail'), []);
  assert.deepEqual(s.flush(), ['F|tail']);
  assert.deepEqual(s.flush(), []);
});

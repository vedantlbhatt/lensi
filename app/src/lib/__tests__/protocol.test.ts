import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LineSplitter, parseLine } from '../protocol';

test('parses each line kind', () => {
  assert.deepEqual(parseLine('T|Breville Barista Express'), { kind: 'title', text: 'Breville Barista Express' });
  assert.deepEqual(parseLine('S|Grinds and pulls espresso.'), { kind: 'summary', text: 'Grinds and pulls espresso.' });
  assert.deepEqual(parseLine('P|500|250|steam wand'), { kind: 'callout', label: 'steam wand', at: { x: 0.5, y: 0.25 } });
  assert.deepEqual(parseLine('M|3|steam wand'), { kind: 'callout', label: 'steam wand', mark: 3 });
  assert.deepEqual(parseLine('M|#4|portafilter'), { kind: 'callout', label: 'portafilter', mark: 4 });
  assert.deepEqual(parseLine('F|Descale every 3 months'), { kind: 'fact', text: 'Descale every 3 months' });
  assert.deepEqual(parseLine('A|Yes.'), { kind: 'answer', text: 'Yes.' });
  assert.deepEqual(parseLine('E|Busy'), { kind: 'error', text: 'Busy' });
});

test('parses walkthrough steps in all three forms', () => {
  assert.deepEqual(parseLine('W|100|900|Press power'), { kind: 'step', text: 'Press power', at: { x: 0.1, y: 0.9 } });
  assert.deepEqual(parseLine('N|2|Turn the dial'), { kind: 'step', text: 'Turn the dial', mark: 2 });
  assert.deepEqual(parseLine('N|0|Wait a minute'), { kind: 'step', text: 'Wait a minute' });
  assert.deepEqual(parseLine('W|Wait for the beep'), { kind: 'step', text: 'Wait for the beep' });
  assert.deepEqual(parseLine('W|left|side|of it'), { kind: 'step', text: 'left side of it' });
});

test('clamps points and keeps pipes in labels', () => {
  assert.deepEqual(parseLine('P|1200|-5|a|b'), { kind: 'callout', label: 'a b', at: { x: 1, y: 0 } });
});

test('rejects junk', () => {
  for (const s of ['', 'hello', 'T|', 'P|x|1|a', 'P|1|2|', 'Z|what', '|T', 'M|x|label', 'M|0|label', 'M|2|', 'N|x|y'])
    assert.equal(parseLine(s), null, s);
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

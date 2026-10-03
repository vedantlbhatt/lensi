import assert from 'node:assert/strict';
import { test } from 'node:test';

import { visionEngine } from '../engines/vision';
import type { EngineEvent, EngineRequest, Region } from '../types';

const box = { x: 0.1, y: 0.1, w: 0.2, h: 0.1 };
const regions: Region[] = [
  { id: 'r1', mark: 1, kind: 'subject', box: { x: 0.1, y: 0.1, w: 0.8, h: 0.8 }, text: 'router' },
  { id: 'r2', mark: 2, kind: 'text', box, text: 'WPA2 KEY: 7H3-L0V3' },
  { id: 'r3', mark: 3, kind: 'barcode', box, text: 'https://example.com/setup' },
  { id: 'r4', mark: 4, kind: 'object', box, text: 'cable' },
];

async function run(req: Partial<EngineRequest>): Promise<EngineEvent[]> {
  const out: EngineEvent[] = [];
  await visionEngine.run({ imageUri: 'x', width: 1, height: 1, lens: 'identify', regions, hint: null, ...req }, (e) => out.push(e), new AbortController().signal);
  return out;
}

test('eyes only: names the subject, says what it read, labels by mark', async () => {
  const ev = await run({});
  assert.deepEqual(ev[0], { kind: 'title', text: 'Router' });
  const summary = ev.find((e) => e.kind === 'summary');
  assert.equal(summary && 'text' in summary ? summary.text : '', 'Read 1 line of text, found 1 code and spotted 1 other thing, all on this phone.');
  const marks = ev.filter((e) => e.kind === 'callout').map((e) => (e.kind === 'callout' ? e.mark : 0));
  assert.deepEqual(marks, [3, 2, 4]);
  assert.ok(ev.some((e) => e.kind === 'fact' && e.text.startsWith('Code links to example.com')));
  assert.ok(ev.some((e) => e.kind === 'callout' && e.label === 'Link · example.com'));
  assert.ok(ev.some((e) => e.kind === 'fact' && e.text === 'Also here: cable'));
});

test('eyes only: questions get an honest answer, not a guess', async () => {
  const ev = await run({ question: 'what is the wifi password?' });
  assert.equal(ev.length, 1);
  assert.equal(ev[0].kind, 'answer');
});

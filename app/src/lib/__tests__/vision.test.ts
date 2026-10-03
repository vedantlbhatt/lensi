import assert from 'node:assert/strict';
import { test } from 'node:test';

import { counted, tapAnswer, visionEngine } from '../engines/vision';
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
  assert.equal(summary && 'text' in summary ? summary.text : '', 'Spotted a router and a cable, read a line of text and found a code, all on this phone.');
  const marks = ev.filter((e) => e.kind === 'callout').map((e) => (e.kind === 'callout' ? e.mark : 0));
  assert.deepEqual(marks, [3, 2, 4]);
  assert.ok(ev.some((e) => e.kind === 'fact' && e.text.startsWith('Code links to example.com')));
  assert.ok(ev.some((e) => e.kind === 'callout' && e.label === 'Link · example.com'));
  assert.ok(ev.some((e) => e.kind === 'callout' && e.label === 'Cable'));
});

test('eyes only: counts what it found by name, most common first', async () => {
  const fruit: Region[] = [
    { id: 's', mark: 1, kind: 'subject', box, text: 'orange' },
    { id: 'a', mark: 2, kind: 'object', box, text: 'orange' },
    { id: 'b', mark: 3, kind: 'object', box, text: 'apple' },
    { id: 'c', mark: 4, kind: 'object', box, text: 'person' },
    { id: 'd', mark: 5, kind: 'object', box, text: 'person' },
    { id: 'e', mark: 6, kind: 'object', box, text: 'person' },
  ];
  const ev = await run({ regions: fruit });
  const summary = ev.find((e) => e.kind === 'summary');
  assert.equal(summary && 'text' in summary ? summary.text : '', 'Spotted three people, two oranges and an apple, all on this phone.');
  // The subject's own class appears twice, so the title counts it.
  assert.deepEqual(ev[0], { kind: 'title', text: 'Two oranges' });
  assert.deepEqual(
    ev.filter((e) => e.kind === 'callout').map((e) => (e.kind === 'callout' ? e.label : '')),
    ['Orange', 'Apple', 'Person', 'Person'],
  );
});

test('counted: articles, irregular plurals, big numbers', () => {
  assert.equal(counted('truck', 1), 'a truck');
  assert.equal(counted('umbrella', 1), 'an umbrella');
  assert.equal(counted('bus', 2), 'two buses');
  assert.equal(counted('person', 12), '12 people');
  assert.equal(counted('knife', 3), 'three knives');
  assert.equal(counted('tv', 1), 'a TV');
});

test('eyes only: questions get an honest answer, not a guess', async () => {
  const ev = await run({ question: 'what is the wifi password?' });
  assert.equal(ev.length, 1);
  assert.equal(ev[0].kind, 'answer');
});

test('eyes only: a tap is answered from what was found there', async () => {
  const scene: Region[] = [
    { id: 's', mark: 1, kind: 'subject', box: { x: 0.1, y: 0.2, w: 0.8, h: 0.6 }, text: 'truck' },
    { id: 't', mark: 2, kind: 'text', box: { x: 0.8, y: 0.7, w: 0.1, h: 0.04 }, text: 'CUBA' },
    { id: 'd', mark: 3, kind: 'object', box: { x: 0.0, y: 0.0, w: 0.1, h: 0.1 }, text: 'dog' },
  ];
  const plate: Region = { id: 'p', mark: 9, kind: 'part', box: { x: 0.79, y: 0.69, w: 0.12, h: 0.06 } };
  const lamp: Region = { id: 'l', mark: 10, kind: 'part', box: { x: 0.25, y: 0.3, w: 0.1, h: 0.1 } };
  const dog: Region = { id: 'g', mark: 11, kind: 'part', box: { x: 0.0, y: 0.0, w: 0.09, h: 0.1 } };
  const sky: Region = { id: 'k', mark: 12, kind: 'part', box: { x: 0.5, y: 0.0, w: 0.2, h: 0.1 } };

  const read = tapAnswer(plate, [...scene, plate]);
  assert.deepEqual(read[0], { kind: 'answer', text: 'It reads “CUBA”.' });
  assert.deepEqual(read[1], { kind: 'callout', label: 'CUBA', mark: 9 });

  const part = tapAnswer(lamp, [...scene, lamp]);
  assert.equal(part.length, 1);
  assert.match(part[0].kind === 'answer' ? part[0].text : '', /^Part of the truck/);

  const whole = tapAnswer(dog, [...scene, dog]);
  assert.deepEqual(whole[1], { kind: 'callout', label: 'Dog', mark: 11 });

  assert.match((tapAnswer(sky, [...scene, sky])[0] as { text: string }).text, /^Outlined on this phone/);

  const ev = await run({ regions: [...scene, plate], question: 'The user tapped the part at mark 9. What is it, and what is it for? Label it.' });
  assert.deepEqual(ev.map((e) => e.kind), ['answer', 'callout']);
});

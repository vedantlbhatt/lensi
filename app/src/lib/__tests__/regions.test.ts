import assert from 'node:assert/strict';
import { test } from 'node:test';

import { anchorFor, buildRegions, describeMarks, iou, regionAt, type AnalysisLike } from '../regions';

const square = (x: number, y: number, s: number) => [
  { x, y },
  { x: x + s, y },
  { x: x + s, y: y + s },
  { x, y: y + s },
];

const base: AnalysisLike = {
  subject: { box: { x: 0.2, y: 0.2, w: 0.6, h: 0.6 }, polygon: square(0.2, 0.2, 0.6) },
  instances: [
    { box: { x: 0.2, y: 0.2, w: 0.6, h: 0.6 }, polygon: square(0.2, 0.2, 0.6) },
    { box: { x: 0.85, y: 0.05, w: 0.1, h: 0.1 }, polygon: square(0.85, 0.05, 0.1) },
  ],
  text: [
    { text: 'POWER', box: { x: 0.3, y: 0.3, w: 0.1, h: 0.04 }, confidence: 0.9 },
    { text: 'x', box: { x: 0.5, y: 0.5, w: 0.01, h: 0.01 }, confidence: 0.9 },
  ],
  barcodes: [],
  objects: [{ label: 'microwave', confidence: 0.8, box: { x: 0.21, y: 0.19, w: 0.58, h: 0.62 } }],
  labels: [{ label: 'appliance', confidence: 0.7 }],
  salient: [],
};

test('iou basics', () => {
  assert.equal(iou({ x: 0, y: 0, w: 1, h: 1 }, { x: 0, y: 0, w: 1, h: 1 }), 1);
  assert.equal(iou({ x: 0, y: 0, w: 1, h: 1 }, { x: 2, y: 2, w: 1, h: 1 }), 0);
});

test('subject comes first, named by the overlapping detector box', () => {
  const { subject, regions } = buildRegions(base);
  assert.equal(subject?.mark, 1);
  assert.equal(subject?.kind, 'subject');
  assert.equal(subject?.text, 'microwave');
  assert.deepEqual(
    regions.map((r) => r.kind),
    ['subject', 'object', 'text'],
  );
  assert.ok(!regions.some((r) => r.text === 'x'), 'drops single characters');
  regions.forEach((r, i) => assert.equal(r.mark, i + 1));
});

test('falls back to detector or saliency when Vision found no subject', () => {
  const noSubject = { ...base, subject: null, instances: [] };
  assert.equal(buildRegions(noSubject).subject?.text, 'microwave');
  const nothing: AnalysisLike = { ...noSubject, objects: [], text: [], salient: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.2 }] };
  assert.equal(buildRegions(nothing).subject?.kind, 'subject');
  assert.equal(buildRegions({ ...nothing, salient: [] }).subject, null);
});

test('regionAt prefers the smallest containing region', () => {
  const { regions } = buildRegions(base);
  assert.equal(regionAt({ x: 0.35, y: 0.32 }, regions)?.text, 'POWER');
  assert.equal(regionAt({ x: 0.6, y: 0.6 }, regions)?.kind, 'subject');
  assert.equal(regionAt({ x: 0.02, y: 0.98 }, regions), null);
});

test('anchors land inside concave shapes', () => {
  const ell = [
    { x: 0, y: 0 },
    { x: 0.2, y: 0 },
    { x: 0.2, y: 0.8 },
    { x: 1, y: 0.8 },
    { x: 1, y: 1 },
    { x: 0, y: 1 },
  ];
  const a = anchorFor({ id: 'r1', mark: 1, kind: 'subject', box: { x: 0, y: 0, w: 1, h: 1 }, polygon: ell });
  const inside = (a.x <= 0.2 && a.y <= 1) || (a.y >= 0.8 && a.y <= 1);
  assert.ok(inside, JSON.stringify(a));
});

test('describeMarks is one line per region with a place', () => {
  const { regions } = buildRegions(base);
  const d = describeMarks(regions).split('\n');
  assert.equal(d.length, regions.length);
  assert.match(d[0], /^1: subject \(microwave\), center$/);
  assert.match(d[2], /^3: text "POWER", /);
});

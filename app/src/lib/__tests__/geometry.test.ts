import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  arcControl,
  centroid,
  fitRect,
  layoutLabels,
  outlinePath,
  pointInPolygon,
  polygonArea,
  simplify,
  smoothClosedPath,
  toView,
} from '../geometry';

test('fitRect cover fills and crops the long side', () => {
  const f = fitRect(3000, 4000, 390, 844, 'cover');
  assert.ok(Math.abs(f.h - 844) < 1e-6);
  assert.ok(f.w > 390);
  assert.ok(Math.abs(f.x + f.w / 2 - 195) < 1e-6);
});

test('fitRect contain letterboxes', () => {
  const f = fitRect(4000, 3000, 390, 844, 'contain');
  assert.equal(f.w, 390);
  assert.ok(f.h < 844 && f.y > 0);
  const p = toView({ x: 0.5, y: 0.5 }, f);
  assert.ok(Math.abs(p.x - 195) < 1e-6 && Math.abs(p.y - 422) < 1e-6);
});

test('fitRect tolerates zero sizes', () => {
  assert.deepEqual(fitRect(0, 0, 100, 200, 'cover'), { x: 0, y: 0, w: 100, h: 200 });
});

test('polygon helpers', () => {
  const sq = [
    { x: 0, y: 0 },
    { x: 1, y: 0 },
    { x: 1, y: 1 },
    { x: 0, y: 1 },
  ];
  assert.equal(polygonArea(sq), 1);
  const c = centroid(sq);
  assert.ok(Math.abs(c.x - 0.5) < 1e-9 && Math.abs(c.y - 0.5) < 1e-9);
  assert.ok(pointInPolygon({ x: 0.5, y: 0.5 }, sq));
  assert.ok(!pointInPolygon({ x: 1.5, y: 0.5 }, sq));
});

test('simplify drops collinear points and keeps corners', () => {
  const line = Array.from({ length: 11 }, (_, i) => ({ x: i, y: 0 }));
  assert.equal(simplify(line, 0.1).length, 2);
  const corner = [
    { x: 0, y: 0 },
    { x: 5, y: 0.01 },
    { x: 10, y: 0 },
    { x: 10, y: 10 },
  ];
  assert.deepEqual(simplify(corner, 0.5), [corner[0], corner[2], corner[3]]);
});

test('smooth paths are closed and well formed', () => {
  const tri = [
    { x: 0, y: 0 },
    { x: 10, y: 0 },
    { x: 5, y: 8 },
  ];
  const d = smoothClosedPath(tri);
  assert.match(d, /^M0 0 C/);
  assert.match(d, / Z$/);
  assert.equal((d.match(/C/g) ?? []).length, 3);
  const o = outlinePath(tri.map((p) => ({ x: p.x / 10, y: p.y / 10 })), { x: 0, y: 0, w: 100, h: 100 });
  assert.match(o, /^M\d/);
  assert.doesNotMatch(o, /NaN/);
});

test('labels never overlap on a side and stay in bounds', () => {
  const anchors = Array.from({ length: 6 }, (_, i) => ({ x: 100 + (i % 2) * 190, y: 300 + i * 4 }));
  const sizes = anchors.map(() => ({ w: 110, h: 28 }));
  const bounds = { x: 12, y: 80, w: 366, h: 600 };
  const slots = layoutLabels(anchors, sizes, bounds, 195);
  for (const s of slots) {
    assert.ok(s.x >= bounds.x - 1e-6 && s.x + 110 <= bounds.x + bounds.w + 1e-6, 'x in bounds');
    assert.ok(s.y >= bounds.y - 1e-6 && s.y + 28 <= bounds.y + bounds.h + 1e-6, 'y in bounds');
  }
  assertNoOverlap(slots, slots.map(() => ({ w: 110, h: 28 })));
});

function assertNoOverlap(slots: ReturnType<typeof layoutLabels>, sizes: { w: number; h: number }[]) {
  for (let i = 0; i < slots.length; i++) {
    for (let j = i + 1; j < slots.length; j++) {
      const a = { ...slots[i], ...sizes[i] };
      const b = { ...slots[j], ...sizes[j] };
      const apart = a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y;
      assert.ok(apart, `labels ${i} and ${j} overlap`);
    }
  }
}

test('labels hanging from opposite sides never meet mid-print', () => {
  // A right-reaching label from a left-of-centre anchor and a left-reaching one
  // from the right edge, at nearly the same height (the truck's door handle and
  // headlamp in the web preview).
  const anchors = [
    { x: 150, y: 276 },
    { x: 370, y: 268 },
    { x: 300, y: 330 },
  ];
  const sizes = [
    { w: 120, h: 28 },
    { w: 100, h: 28 },
    { w: 110, h: 28 },
  ];
  const bounds = { x: 8, y: 100, w: 377, h: 460 };
  const slots = layoutLabels(anchors, sizes, bounds, 196, { gap: 8, reach: 30 });
  assertNoOverlap(slots, sizes);
  for (let i = 0; i < slots.length; i++) {
    assert.ok(Math.abs(slots[i].y + 14 - anchors[i].y) < 80, 'stays near its anchor');
  }
});

test('labels flip sides when the preferred side has no room', () => {
  const slots = layoutLabels([{ x: 20, y: 200 }], [{ w: 120, h: 28 }], { x: 10, y: 0, w: 370, h: 800 }, 195);
  assert.equal(slots[0].side, 1);
});

test('arc bulges upward', () => {
  const c = arcControl({ x: 0, y: 100 }, { x: 100, y: 100 });
  assert.ok(c.y < 100);
  const c2 = arcControl({ x: 100, y: 100 }, { x: 0, y: 100 });
  assert.ok(c2.y < 100);
});

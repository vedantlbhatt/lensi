import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  arcControl,
  centroid,
  smallestShapeAt,
  fitRect,
  layoutTags,
  outlinePath,
  pointInPolygon,
  polygonArea,
  polygonIoU,
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

test('tags sit on their anchors when there is room', () => {
  const anchors = [
    { x: 120, y: 200 },
    { x: 260, y: 420 },
  ];
  const sizes = [
    { w: 80, h: 26 },
    { w: 100, h: 26 },
  ];
  const slots = layoutTags(anchors, sizes, { x: 8, y: 60, w: 377, h: 600 });
  slots.forEach((s, i) => {
    assert.equal(s.x + sizes[i].w / 2, anchors[i].x);
    assert.equal(s.y + sizes[i].h / 2, anchors[i].y);
  });
});

test('tags that would collide step apart, stay near their things and in bounds', () => {
  // Three people standing close together, as in the store-aisle clip.
  const anchors = [
    { x: 150, y: 300 },
    { x: 170, y: 306 },
    { x: 160, y: 312 },
  ];
  const sizes = anchors.map(() => ({ w: 72, h: 26 }));
  const bounds = { x: 8, y: 80, w: 377, h: 600 };
  const slots = layoutTags(anchors, sizes, bounds, { gap: 4 });
  assertNoOverlap(slots, sizes);
  slots.forEach((s, i) => {
    assert.ok(Math.hypot(s.x + 36 - anchors[i].x, s.y + 13 - anchors[i].y) <= 60, 'stays next to its thing');
    assert.ok(s.x >= bounds.x && s.x + 72 <= bounds.x + bounds.w, 'x in bounds');
  });
});

test('tags near an edge are pulled inside', () => {
  const slots = layoutTags([{ x: 10, y: 70 }], [{ w: 120, h: 26 }], { x: 8, y: 60, w: 377, h: 600 });
  assert.equal(slots[0].x, 8);
  assert.equal(slots[0].y, 60);
});

function assertNoOverlap(slots: ReturnType<typeof layoutTags>, sizes: { w: number; h: number }[]) {
  for (let i = 0; i < slots.length; i++) {
    for (let j = i + 1; j < slots.length; j++) {
      const a = { ...slots[i], ...sizes[i] };
      const b = { ...slots[j], ...sizes[j] };
      const apart = a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y;
      assert.ok(apart, `tags ${i} and ${j} overlap`);
    }
  }
}

test('arc bulges upward', () => {
  const c = arcControl({ x: 0, y: 100 }, { x: 100, y: 100 });
  assert.ok(c.y < 100);
  const c2 = arcControl({ x: 100, y: 100 }, { x: 0, y: 100 });
  assert.ok(c2.y < 100);
});

test('a tap picks the smallest shape it is inside', () => {
  const truck = [{ x: 0.1, y: 0.2 }, { x: 0.95, y: 0.2 }, { x: 0.95, y: 0.7 }, { x: 0.1, y: 0.7 }];
  const tyre = [{ x: 0.62, y: 0.47 }, { x: 0.87, y: 0.47 }, { x: 0.87, y: 0.65 }, { x: 0.62, y: 0.65 }];
  assert.equal(smallestShapeAt({ x: 0.78, y: 0.54 }, [truck, tyre]), tyre);
  assert.equal(smallestShapeAt({ x: 0.3, y: 0.4 }, [truck, tyre]), truck);
  assert.equal(smallestShapeAt({ x: 0.02, y: 0.05 }, [truck, tyre]), null);
  // Degenerate shapes are never picked.
  assert.equal(smallestShapeAt({ x: 0.5, y: 0.5 }, [[{ x: 0, y: 0 }, { x: 1, y: 1 }]]), null);
});


test('polygonIoU: the same shape, half of it, and none of it', () => {
  const sq = (x: number, y: number, s: number) => [
    { x, y },
    { x: x + s, y },
    { x: x + s, y: y + s },
    { x, y: y + s },
  ];
  assert.ok(polygonIoU(sq(0, 0, 1), sq(0, 0, 1)) > 0.99);
  // Overlapping by half its width: 1/3 of the union.
  assert.ok(Math.abs(polygonIoU(sq(0, 0, 1), sq(0.5, 0, 1)) - 1 / 3) < 0.03);
  assert.equal(polygonIoU(sq(0, 0, 1), sq(2, 2, 1)), 0);
});

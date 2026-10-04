import assert from 'node:assert/strict';
import { test } from 'node:test';

import { nextZoomStop, STRIP_PAD, stripIndex, stripTick, zoomAfterDrag, zoomText } from '../strip';

// A 344-point strip: 300 between its ends, so 5 things get 60 points each.
const W = 300 + 2 * STRIP_PAD;

test('the strip is cut into equal stretches, in order', () => {
  assert.equal(stripIndex(STRIP_PAD + 30, W, 5), 0);
  assert.equal(stripIndex(STRIP_PAD + 90, W, 5), 1);
  assert.equal(stripIndex(STRIP_PAD + 299, W, 5), 4);
  // Off either end: the nearest thing.
  assert.equal(stripIndex(0, W, 5), 0);
  assert.equal(stripIndex(W + 40, W, 5), 4);
  assert.equal(stripIndex(100, W, 0), -1);
});

test('a finger on the line between two things does not flicker', () => {
  // Just past the 0|1 line: still 0 until 5 points past it, either way.
  assert.equal(stripIndex(STRIP_PAD + 61, W, 5, 0), 0);
  assert.equal(stripIndex(STRIP_PAD + 66, W, 5, 0), 1);
  assert.equal(stripIndex(STRIP_PAD + 58, W, 5, 1), 1);
  assert.equal(stripIndex(STRIP_PAD + 54, W, 5, 1), 0);
  // A fast slide skips straight on.
  assert.equal(stripIndex(STRIP_PAD + 250, W, 5, 0), 4);
});

test('each thing sits in the middle of its stretch', () => {
  assert.equal(stripTick(0, W, 5), STRIP_PAD + 30);
  assert.equal(stripTick(4, W, 5), STRIP_PAD + 270);
  for (let k = 0; k < 5; k++) assert.equal(stripIndex(stripTick(k, W, 5), W, 5), k);
});

test('zoom is written the Camera app way', () => {
  assert.equal(zoomText(0.5), '.5');
  assert.equal(zoomText(0.62), '.6');
  assert.equal(zoomText(1), '1');
  assert.equal(zoomText(0.999), '1');
  assert.equal(zoomText(2.7), '2.7');
  assert.equal(zoomText(2.04), '2');
  assert.equal(zoomText(9.96), '10');
});

test('a tap goes to the next stop the camera can do', () => {
  assert.equal(nextZoomStop(1, 0.5, 10), 2);
  assert.equal(nextZoomStop(2.7, 0.5, 10), 5);
  assert.equal(nextZoomStop(5, 0.5, 10), 0.5);
  assert.equal(nextZoomStop(7, 1, 10), 1);
  assert.equal(nextZoomStop(0.6, 0.5, 10), 1);
});

test('dragging left zooms in, and lets go exactly where it stopped', () => {
  const span = 300;
  assert.ok(Math.abs(zoomAfterDrag(1, -span * Math.log(2), span, 0.5, 10) - 2) < 1e-9);
  assert.ok(Math.abs(zoomAfterDrag(2, span * Math.log(2), span, 0.5, 10) - 1) < 1e-9);
  // 2.7x is 2.7x, not a stop.
  assert.ok(Math.abs(zoomAfterDrag(1, -span * Math.log(2.7), span, 0.5, 10) - 2.7) < 1e-9);
  assert.equal(zoomAfterDrag(1, -5000, span, 0.5, 10), 10);
  assert.equal(zoomAfterDrag(1, 5000, span, 0.5, 10), 0.5);
});

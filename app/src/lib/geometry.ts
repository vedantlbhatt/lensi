import type { Box, Pt } from './types';

/** Where the media's pixels land inside a view. */
export type Fit = { x: number; y: number; w: number; h: number };

export function fitRect(
  mediaW: number,
  mediaH: number,
  viewW: number,
  viewH: number,
  mode: 'cover' | 'contain',
): Fit {
  if (mediaW <= 0 || mediaH <= 0 || viewW <= 0 || viewH <= 0) return { x: 0, y: 0, w: viewW, h: viewH };
  const scale =
    mode === 'cover' ? Math.max(viewW / mediaW, viewH / mediaH) : Math.min(viewW / mediaW, viewH / mediaH);
  const w = mediaW * scale;
  const h = mediaH * scale;
  return { x: (viewW - w) / 2, y: (viewH - h) / 2, w, h };
}

export const toView = (p: Pt, f: Fit): Pt => ({ x: f.x + p.x * f.w, y: f.y + p.y * f.h });
export const fromView = (p: Pt, f: Fit): Pt => ({ x: (p.x - f.x) / f.w, y: (p.y - f.y) / f.h });

export function boxToView(b: Box, f: Fit): Box {
  return { x: f.x + b.x * f.w, y: f.y + b.y * f.h, w: b.w * f.w, h: b.h * f.h };
}

export const boxCenter = (b: Box): Pt => ({ x: b.x + b.w / 2, y: b.y + b.h / 2 });
export const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
export const dist = (a: Pt, b: Pt) => Math.hypot(a.x - b.x, a.y - b.y);

export function polygonArea(pts: Pt[]): number {
  let s = 0;
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i];
    const b = pts[(i + 1) % pts.length];
    s += a.x * b.y - b.x * a.y;
  }
  return Math.abs(s) / 2;
}

export function centroid(pts: Pt[]): Pt {
  if (pts.length === 0) return { x: 0.5, y: 0.5 };
  let a = 0;
  let cx = 0;
  let cy = 0;
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i];
    const q = pts[(i + 1) % pts.length];
    const cross = p.x * q.y - q.x * p.y;
    a += cross;
    cx += (p.x + q.x) * cross;
    cy += (p.y + q.y) * cross;
  }
  if (Math.abs(a) < 1e-9) {
    const n = pts.length;
    return { x: pts.reduce((s, p) => s + p.x, 0) / n, y: pts.reduce((s, p) => s + p.y, 0) / n };
  }
  return { x: cx / (3 * a), y: cy / (3 * a) };
}

export function boundsOf(pts: Pt[]): Box {
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const p of pts) {
    x0 = Math.min(x0, p.x);
    y0 = Math.min(y0, p.y);
    x1 = Math.max(x1, p.x);
    y1 = Math.max(y1, p.y);
  }
  if (!Number.isFinite(x0)) return { x: 0, y: 0, w: 0, h: 0 };
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

export function pointInPolygon(p: Pt, poly: Pt[]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i];
    const b = poly[j];
    if (a.y > p.y !== b.y > p.y && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y + 1e-12) + a.x) inside = !inside;
  }
  return inside;
}

export const pointInBox = (p: Pt, b: Box) => p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h;

/** How much two shapes are the same shape (intersection over union), sampled on a grid over both. */
export function polygonIoU(a: Pt[], b: Pt[], grid = 48): number {
  if (a.length < 3 || b.length < 3) return 0;
  const ba = boundsOf(a);
  const bb = boundsOf(b);
  const x0 = Math.min(ba.x, bb.x);
  const y0 = Math.min(ba.y, bb.y);
  const w = Math.max(ba.x + ba.w, bb.x + bb.w) - x0;
  const h = Math.max(ba.y + ba.h, bb.y + bb.h) - y0;
  let both = 0;
  let either = 0;
  for (let j = 0; j < grid; j++) {
    for (let i = 0; i < grid; i++) {
      const p = { x: x0 + ((i + 0.5) / grid) * w, y: y0 + ((j + 0.5) / grid) * h };
      const inA = pointInPolygon(p, a);
      const inB = pointInPolygon(p, b);
      if (inA && inB) both++;
      if (inA || inB) either++;
    }
  }
  return either ? both / either : 0;
}

/** What a tap at `p` means among overlapping shapes: the smallest one it's inside (a tyre over the truck). */
export function smallestShapeAt(p: Pt, shapes: Pt[][]): Pt[] | null {
  let best: Pt[] | null = null;
  let bestArea = Infinity;
  for (const s of shapes) {
    if (s.length < 3 || !pointInPolygon(p, s)) continue;
    const a = polygonArea(s);
    if (a < bestArea) {
      best = s;
      bestArea = a;
    }
  }
  return best;
}

/** Ramer–Douglas–Peucker on an open polyline. */
export function simplify(pts: Pt[], epsilon: number): Pt[] {
  if (pts.length < 3) return pts.slice();
  const keep = new Uint8Array(pts.length);
  keep[0] = 1;
  keep[pts.length - 1] = 1;
  const stack: [number, number][] = [[0, pts.length - 1]];
  while (stack.length) {
    const [s, e] = stack.pop()!;
    const a = pts[s];
    const b = pts[e];
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = Math.hypot(dx, dy) || 1e-12;
    let maxD = -1;
    let idx = -1;
    for (let i = s + 1; i < e; i++) {
      const d = Math.abs(dy * pts[i].x - dx * pts[i].y + b.x * a.y - b.y * a.x) / len;
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD > epsilon && idx > 0) {
      keep[idx] = 1;
      stack.push([s, idx], [idx, e]);
    }
  }
  return pts.filter((_, i) => keep[i]);
}

/**
 * Closed polygon → smooth SVG path through every vertex (centripetal-ish
 * Catmull–Rom turned into cubic Béziers). `tension` 0 = straight lines.
 */
export function smoothClosedPath(pts: Pt[], tension = 0.5): string {
  const n = pts.length;
  if (n === 0) return '';
  if (n < 3) return `M${pts.map((p) => `${r(p.x)} ${r(p.y)}`).join(' L')} Z`;
  const t = tension / 3;
  let d = `M${r(pts[0].x)} ${r(pts[0].y)}`;
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n];
    const p1 = pts[i];
    const p2 = pts[(i + 1) % n];
    const p3 = pts[(i + 2) % n];
    const c1 = { x: p1.x + (p2.x - p0.x) * t, y: p1.y + (p2.y - p0.y) * t };
    const c2 = { x: p2.x - (p3.x - p1.x) * t, y: p2.y - (p3.y - p1.y) * t };
    d += ` C${r(c1.x)} ${r(c1.y)} ${r(c2.x)} ${r(c2.y)} ${r(p2.x)} ${r(p2.y)}`;
  }
  return `${d} Z`;
}

const r = (v: number) => Math.round(v * 10) / 10;

/** Normalized polygon → smooth view-space path. Drops near-duplicate vertices first. */
export function outlinePath(poly: Pt[], f: Fit, tension = 0.5): string {
  const view = poly.map((p) => toView(p, f));
  const perimeter = view.reduce((s, p, i) => s + dist(p, view[(i + 1) % view.length]), 0);
  // ~0.4% of the perimeter, never below a pixel: keeps corners, drops staircase noise.
  const eps = Math.max(1, perimeter * 0.004);
  const closed = [...view, view[0]];
  const simple = simplify(closed, eps).slice(0, -1);
  return smoothClosedPath(simple.length >= 3 ? simple : view, tension);
}

export function roundedBoxPath(b: Box, radius: number): string {
  const rr = Math.min(radius, b.w / 2, b.h / 2);
  const { x, y, w, h } = b;
  return [
    `M${r(x + rr)} ${r(y)}`,
    `H${r(x + w - rr)}`,
    `Q${r(x + w)} ${r(y)} ${r(x + w)} ${r(y + rr)}`,
    `V${r(y + h - rr)}`,
    `Q${r(x + w)} ${r(y + h)} ${r(x + w - rr)} ${r(y + h)}`,
    `H${r(x + rr)}`,
    `Q${r(x)} ${r(y + h)} ${r(x)} ${r(y + h - rr)}`,
    `V${r(y + rr)}`,
    `Q${r(x)} ${r(y)} ${r(x + rr)} ${r(y)}`,
    'Z',
  ].join(' ');
}

export type LabelSlot = {
  /** The point the tag names (view space). */
  anchor: Pt;
  /** Top-left of the tag (view space). */
  x: number;
  y: number;
};

/**
 * Tags sit on the things they name, centred on the anchor. One that would
 * cover a tag already placed moves to the nearest spot that clears every
 * other tag (beside or above or below them), so it still sits on or next to
 * its thing. Tags stay inside `bounds`.
 */
export function layoutTags(
  anchors: Pt[],
  sizes: { w: number; h: number }[],
  bounds: { x: number; y: number; w: number; h: number },
  opts: { gap?: number } = {},
): LabelSlot[] {
  const gap = opts.gap ?? 4;
  const slots: LabelSlot[] = new Array(anchors.length);
  const placed: { x: number; y: number; w: number; h: number }[] = [];
  const order = anchors.map((_, i) => i).sort((p, q) => anchors[p].y - anchors[q].y);
  for (const i of order) {
    const a = anchors[i];
    const { w, h } = sizes[i];
    const cx = (v: number) => clamp(v, bounds.x, bounds.x + bounds.w - w);
    const cy = (v: number) => clamp(v, bounds.y, bounds.y + bounds.h - h);
    const x0 = cx(a.x - w / 2);
    const y0 = cy(a.y - h / 2);
    const free = (x: number, y: number) =>
      placed.every((r) => x + w + gap <= r.x + 1e-6 || r.x + r.w + gap <= x + 1e-6 || y + h + gap <= r.y + 1e-6 || r.y + r.h + gap <= y + 1e-6);
    const xs = [x0, ...placed.flatMap((r) => [cx(r.x - w - gap), cx(r.x + r.w + gap)])];
    const ys = [y0, ...placed.flatMap((r) => [cy(r.y - h - gap), cy(r.y + r.h + gap)])];
    let best = { x: x0, y: y0 };
    let bestD = Infinity;
    for (const x of xs) {
      for (const y of ys) {
        const d = Math.hypot(x - x0, y - y0);
        if (d < bestD && free(x, y)) {
          best = { x, y };
          bestD = d;
        }
      }
    }
    placed.push({ ...best, w, h });
    slots[i] = { anchor: a, ...best };
  }
  return slots;
}

/**
 * Arc between two points for the walkthrough pointer: bulges perpendicular to
 * the travel direction, always "up" so it reads like a thrown object.
 */
export function arcControl(a: Pt, b: Pt, bulge = 0.28): Pt {
  const mx = (a.x + b.x) / 2;
  const my = (a.y + b.y) / 2;
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const len = Math.hypot(dx, dy);
  let nx = -dy / (len || 1);
  let ny = dx / (len || 1);
  if (ny > 0) {
    nx = -nx;
    ny = -ny;
  }
  return { x: mx + nx * len * bulge, y: my + ny * len * bulge };
}

export function quadAt(a: Pt, c: Pt, b: Pt, t: number): Pt {
  'worklet';
  const u = 1 - t;
  return { x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y };
}

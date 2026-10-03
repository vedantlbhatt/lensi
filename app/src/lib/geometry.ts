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
  /** Where the dot sits (view space). */
  anchor: Pt;
  /** Top-left of the label pill (view space). */
  x: number;
  y: number;
  side: -1 | 1;
  /** Where the leader line meets the pill. */
  attach: Pt;
};

/**
 * Exploded-diagram layout: each label goes to the side of the subject its
 * anchor is on, stays as close to the anchor's height as it can, and never
 * overlaps another label on that side. Labels stay inside `bounds`.
 */
export function layoutLabels(
  anchors: Pt[],
  sizes: { w: number; h: number }[],
  bounds: { x: number; y: number; w: number; h: number },
  centerX: number,
  opts: { gap?: number; reach?: number } = {},
): LabelSlot[] {
  const gap = opts.gap ?? 8;
  const reach = opts.reach ?? 34;
  const slots: LabelSlot[] = new Array(anchors.length);
  const sides: Record<-1 | 1, number[]> = { [-1]: [], [1]: [] };

  anchors.forEach((a, i) => {
    let side: -1 | 1 = a.x < centerX ? -1 : 1;
    const w = sizes[i].w;
    // Not enough room on the preferred side: flip.
    if (side === -1 && a.x - reach - w < bounds.x) side = 1;
    else if (side === 1 && a.x + reach + w > bounds.x + bounds.w) side = -1;
    sides[side].push(i);
  });

  for (const side of [-1, 1] as const) {
    const idx = sides[side].sort((p, q) => anchors[p].y - anchors[q].y);
    // Desired centers, then a top-down sweep pushing overlaps down…
    const ys = idx.map((i) => anchors[i].y - sizes[i].h / 2);
    for (let k = 0; k < idx.length; k++) {
      const minY = k === 0 ? bounds.y : ys[k - 1] + sizes[idx[k - 1]].h + gap;
      ys[k] = Math.max(ys[k], minY);
    }
    // …and a bottom-up sweep pulling everything back inside the bounds.
    for (let k = idx.length - 1; k >= 0; k--) {
      const maxY = k === idx.length - 1 ? bounds.y + bounds.h - sizes[idx[k]].h : ys[k + 1] - sizes[idx[k]].h - gap;
      ys[k] = Math.min(ys[k], maxY);
    }
    idx.forEach((i, k) => {
      const a = anchors[i];
      const { w, h } = sizes[i];
      const y = clamp(ys[k], bounds.y, bounds.y + bounds.h - h);
      let x = side === -1 ? a.x - reach - w : a.x + reach;
      x = clamp(x, bounds.x, bounds.x + bounds.w - w);
      const attach = { x: side === -1 ? x + w : x, y: y + h / 2 };
      slots[i] = { anchor: a, x, y, side, attach };
    });
  }
  return slots;
}

/** A soft S-curve from the dot to the pill, leaving horizontally at both ends. */
export function leaderPath(from: Pt, to: Pt): string {
  const mx = (from.x + to.x) / 2;
  return `M${r(from.x)} ${r(from.y)} C${r(mx)} ${r(from.y)} ${r(mx)} ${r(to.y)} ${r(to.x)} ${r(to.y)}`;
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

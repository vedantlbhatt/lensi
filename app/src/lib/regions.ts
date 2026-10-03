import { boundsOf, boxCenter, dist, pointInBox, pointInPolygon, polygonArea } from './geometry';
import type { Box, Pt, Region } from './types';

/** What the native analyzer returns (see modules/lensi-ar/src/types.ts). */
export type AnalysisLike = {
  subject: { box: Box; polygon: Pt[] } | null;
  instances: { box: Box; polygon: Pt[] }[];
  text: { text: string; box: Box; confidence: number }[];
  barcodes: { payload: string; symbology: string; box: Box }[];
  objects: { label: string; confidence: number; box: Box }[];
  labels: { label: string; confidence: number }[];
  salient: Box[];
  parts?: { polygon: Pt[]; box: Box; score: number }[];
};

const area = (b: Box) => Math.max(0, b.w) * Math.max(0, b.h);

export function iou(a: Box, b: Box): number {
  const x0 = Math.max(a.x, b.x);
  const y0 = Math.max(a.y, b.y);
  const x1 = Math.min(a.x + a.w, b.x + b.w);
  const y1 = Math.min(a.y + a.h, b.y + b.h);
  const i = Math.max(0, x1 - x0) * Math.max(0, y1 - y0);
  const u = area(a) + area(b) - i;
  return u > 0 ? i / u : 0;
}

// Vision's classifier often leads with scene words ("outdoor", "structure")
// that make poor names for the thing in front of the camera.
const SCENE_WORDS = new Set([
  'outdoor', 'indoor', 'structure', 'people', 'adult', 'land', 'sky', 'blue_sky', 'cloudy',
  'sunset_sunrise', 'night_sky', 'light', 'texture', 'pattern', 'material', 'art', 'abstract',
  'wood_processed', 'raw_glass', 'raw_metal', 'foliage', 'document', 'text', 'machine', 'illustrations',
]);

/** The classifier's best label that names a thing rather than a scene, readable. */
export function thingLabel(labels: { label: string; confidence: number }[]): string | undefined {
  // The native side sends identifiers with spaces ("night sky"); the list is in Vision's own form.
  const l = labels.find((x) => x.confidence >= 0.1 && !SCENE_WORDS.has(x.label.toLowerCase().replace(/ /g, '_')));
  return l?.label.replace(/_/g, ' ');
}

/**
 * A small box cut off by the photo's edge: the detector sees a sliver of
 * something and guesses (a car's roof read as a "bottle"). Not worth a name.
 */
function sliver(b: Box): boolean {
  const edge = b.x <= 0.01 || b.y <= 0.01 || b.x + b.w >= 0.99 || b.y + b.h >= 0.99;
  return edge && b.w * b.h < 0.04;
}

/** Detector classes that are usually what the subject stands on. */
const SURFACES = new Set(['dining table', 'bed', 'couch', 'bench']);

const MAX_TEXT = 8;
const MAX_OBJECTS = 5;
const MAX_PARTS = 6;
const MAX_REGIONS = 18;

/**
 * Turns raw on-device findings into numbered regions, most useful first. The
 * numbers are what gets drawn on the image for set-of-marks prompting, so the
 * order is stable for a given analysis.
 */
export function buildRegions(a: AnalysisLike): { subject: Region | null; regions: Region[] } {
  const regions: Region[] = [];
  const add = (r: Omit<Region, 'id' | 'mark'>) => {
    if (regions.length >= MAX_REGIONS) return;
    const mark = regions.length + 1;
    regions.push({ ...r, id: `r${mark}`, mark });
  };

  const subjectSrc = a.subject ?? a.instances[0] ?? null;
  const detected = a.objects.filter((o) => !sliver(o.box));
  // Most the subject: big, central and confident (confidence alone picks a small car at the
  // edge). Things other things stand on rarely are, when anything else is in the frame.
  const prominence = (o: { label: string; confidence: number; box: Box }) =>
    (SURFACES.has(o.label) ? 0.2 : 1) *
    o.confidence *
    Math.sqrt(o.box.w * o.box.h) *
    Math.max(0.2, 1 - Math.hypot(o.box.x + o.box.w / 2 - 0.5, o.box.y + o.box.h / 2 - 0.5) * 1.3);
  const topObject = [...detected].sort((p, q) => prominence(q) - prominence(p))[0];
  if (subjectSrc) {
    // Name the subject after whichever detector box overlaps it most.
    const named = detected
      .map((o) => ({ o, s: iou(o.box, subjectSrc.box) }))
      .filter((x) => x.s > 0.35)
      .sort((p, q) => q.s - p.s)[0]?.o;
    add({
      kind: 'subject',
      box: subjectSrc.box,
      polygon: subjectSrc.polygon,
      text: named?.label ?? thingLabel(a.labels),
      confidence: named?.confidence,
    });
  } else if (topObject) {
    add({ kind: 'subject', box: topObject.box, text: topObject.label, confidence: topObject.confidence });
  } else if (a.salient[0]) {
    add({ kind: 'subject', box: a.salient[0], text: thingLabel(a.labels) });
  }
  const subject = regions[0] ?? null;

  // Other foreground instances.
  for (const inst of a.instances) {
    if (subject && iou(inst.box, subject.box) > 0.6) continue;
    if (area(inst.box) < 0.002) continue;
    const named = detected.find((o) => iou(o.box, inst.box) > 0.4);
    add({ kind: 'object', box: inst.box, polygon: inst.polygon, text: named?.label });
  }

  // Detector objects that no instance covered.
  const objects = [...detected].sort((p, q) => q.confidence - p.confidence).slice(0, MAX_OBJECTS);
  for (const o of objects) {
    if (regions.some((r) => iou(r.box, o.box) > 0.5)) continue;
    add({ kind: 'object', box: o.box, text: o.label, confidence: o.confidence });
  }

  for (const b of a.barcodes) add({ kind: 'barcode', box: b.box, text: b.payload });

  // SAM's part proposals: what the model can point at inside the thing (a knob,
  // a port, a handle). Skip ones that repeat a region already marked.
  const parts = [...(a.parts ?? [])].sort((p, q) => q.score - p.score);
  let partCount = 0;
  for (const p of parts) {
    if (partCount >= MAX_PARTS) break;
    if (p.polygon.length < 3 || regions.some((r) => iou(r.box, p.box) > 0.6)) continue;
    add({ kind: 'part', box: p.box, polygon: p.polygon, confidence: p.score });
    partCount++;
  }

  // Biggest, most confident text first; skip single stray characters.
  const text = a.text
    .filter((t) => t.text.trim().length > 1)
    .sort((p, q) => area(q.box) * q.confidence - area(p.box) * p.confidence)
    .slice(0, MAX_TEXT);
  for (const t of text) add({ kind: 'text', box: t.box, text: t.text.trim(), confidence: t.confidence });

  if (regions.length === 0) for (const s of a.salient.slice(0, 2)) add({ kind: 'salient', box: s });

  return { subject, regions };
}

export const regionCenter = (r: Region): Pt => boxCenter(r.box);

/**
 * The best region for a point an engine produced: the smallest region whose
 * outline (or box) contains it, otherwise the nearest center within reach.
 */
export function regionAt(p: Pt, regions: Region[], reach = 0.08): Region | null {
  const hits = regions.filter((r) => (r.polygon && r.polygon.length > 2 ? pointInPolygon(p, r.polygon) : pointInBox(p, r.box)));
  if (hits.length) {
    return hits.sort((a, b) => regionArea(a) - regionArea(b))[0];
  }
  let best: Region | null = null;
  let bestD = reach;
  for (const r of regions) {
    const d = dist(p, regionCenter(r));
    if (d < bestD) {
      bestD = d;
      best = r;
    }
  }
  return best;
}

export function regionArea(r: Region): number {
  return r.polygon && r.polygon.length > 2 ? polygonArea(r.polygon) : area(r.box);
}

/** Where a label for this region should point: inside the shape, near its middle. */
export function anchorFor(r: Region): Pt {
  const c = regionCenter(r);
  if (!r.polygon || r.polygon.length < 3 || pointInPolygon(c, r.polygon)) return c;
  // Concave shape whose box center falls outside: use the vertex-mean of the
  // polygon pulled toward the box center until it lands inside.
  const b = boundsOf(r.polygon);
  for (let t = 0.1; t <= 1; t += 0.1) {
    for (const p of r.polygon) {
      const q = { x: p.x + (c.x - p.x) * t, y: p.y + (c.y - p.y) * t };
      if (pointInPolygon(q, r.polygon) && pointInBox(q, b)) return q;
    }
  }
  return r.polygon[0];
}

/** Coarse words for where a box sits, for text descriptions of marks. */
export function placeWords(b: Box): string {
  const c = boxCenter(b);
  const v = c.y < 0.33 ? 'top' : c.y > 0.67 ? 'bottom' : 'middle';
  const h = c.x < 0.33 ? 'left' : c.x > 0.67 ? 'right' : 'center';
  return v === 'middle' && h === 'center' ? 'center' : `${v} ${h}`;
}

/** One line per mark, used in prompts for both on-device and cloud models. */
export function describeMarks(regions: Region[]): string {
  return regions
    .map((r) => {
      const what =
        r.kind === 'text'
          ? `text "${r.text}"`
          : r.kind === 'barcode'
            ? `barcode "${r.text}"`
            : r.text
              ? `${r.kind} (${r.text})`
              : r.kind;
      return `${r.mark}: ${what}, ${placeWords(r.box)}`;
    })
    .join('\n');
}

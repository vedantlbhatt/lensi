import { fitRect, layoutTags, toView, type Fit, type LabelSlot } from '../../lib/geometry';
import type { Callout, Capture } from '../../lib/types';

export const TOP_BAR = 52;
/** Height the bottom card takes when it is down, its bottom margin included. */
export const CARD_PEEK = 274;
export const FRAME_RADIUS = 26;

/** Tag metrics: SF Pro Text Semibold 13 on a white tag. */
export const LABEL = {
  size: 13,
  padX: 9,
  height: 26,
  maxChars: 24,
};

export function labelText(s: string): string {
  const t = s.trim();
  return t.length > LABEL.maxChars ? `${t.slice(0, LABEL.maxChars - 1).trimEnd()}…` : t;
}

/**
 * A close estimate of a tag's width (React Native can't measure text
 * synchronously). Advances are SF Pro Text Semibold's, in ems, rounded up a
 * little so the estimate errs wide; the tag itself sizes to its text and is
 * centred in this width, so a near miss never shows.
 */
export function labelWidth(s: string): number {
  let em = 0;
  for (const ch of labelText(s)) {
    em += /[ijl.,:;'!|]/.test(ch) ? 0.28 : /[frt() -]/.test(ch) ? 0.38 : /[mwMW@]/.test(ch) ? 0.9 : /[A-Z0-9]/.test(ch) ? 0.68 : 0.58;
  }
  return Math.ceil(em * LABEL.size + LABEL.padX * 2 + 4);
}

export type Stage = {
  /** Where the photo sits once framed, in screen points. */
  frame: Fit;
  /** Where the photo sits full-bleed (cover), for the hand-off from the camera. */
  bleed: Fit;
  /** Region labels may use. */
  labelBounds: { x: number; y: number; w: number; h: number };
};

export function stageFor(
  media: { width: number; height: number },
  screen: { width: number; height: number },
  insets: { top: number; bottom: number },
): Stage {
  const top = insets.top + TOP_BAR + 6;
  const bottom = screen.height - (CARD_PEEK + insets.bottom) - 14;
  const side = 14;
  const avail = { x: side, y: top, w: screen.width - side * 2, h: Math.max(120, bottom - top) };
  const inner = fitRect(media.width, media.height, avail.w, avail.h, 'contain');
  const frame = { x: avail.x + inner.x, y: avail.y + inner.y, w: inner.w, h: inner.h };
  const bleed = fitRect(media.width, media.height, screen.width, screen.height, 'cover');
  return {
    frame,
    bleed,
    labelBounds: { x: 8, y: top + 2, w: screen.width - 16, h: Math.max(80, bottom - top - 4) },
  };
}

export type PlacedCallout = Callout & { slot: LabelSlot; width: number };

export function placeCallouts(callouts: Callout[], stage: Stage): PlacedCallout[] {
  if (!callouts.length) return [];
  const anchors = callouts.map((c) => toView(c.at, stage.frame));
  const sizes = callouts.map((c) => ({ w: labelWidth(c.label), h: LABEL.height }));
  const slots = layoutTags(anchors, sizes, stage.labelBounds, { gap: 4 });
  return callouts.map((c, i) => ({ ...c, slot: slots[i], width: sizes[i].w }));
}

/** The steps the walkthrough should play: the newest answer that has steps, else the capture's own. */
export function activeSteps(c: Capture) {
  for (let i = c.thread.length - 1; i >= 0; i--) {
    const s = c.thread[i].steps;
    if (s && s.length) return { steps: s, key: c.thread[i].id, pending: c.thread[i].pending };
  }
  return { steps: c.annotation.steps, key: 'capture', pending: c.status === 'analyzing' };
}

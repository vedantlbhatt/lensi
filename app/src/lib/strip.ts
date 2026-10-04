/**
 * The camera's two sliders as numbers: which thing a finger on the strip is on, and where a
 * drag or a tap on the zoom dial takes the zoom. Pure, so it's tested.
 */

/** The strip's ends, where nothing sits (points). */
export const STRIP_PAD = 22;
/** Past a boundary by this much (points) before the next thing takes over: a finger resting on the line doesn't flicker. */
export const STRIP_HYSTERESIS = 5;

/**
 * Which of `n` things a finger at `x` (points) on a strip `width` wide is on: the strip is cut
 * into `n` equal stretches between its ends, in order. `current` is the one it was on (-1: none).
 */
export function stripIndex(x: number, width: number, n: number, current = -1): number {
  if (n <= 0) return -1;
  const seg = Math.max(1, width - 2 * STRIP_PAD) / n;
  const at = x - STRIP_PAD;
  let i = Math.max(0, Math.min(n - 1, Math.floor(at / seg)));
  if (current >= 0 && current < n && i !== current) {
    const past = i > current ? at - (current + 1) * seg : current * seg - at;
    if (past < STRIP_HYSTERESIS) i = current;
  }
  return i;
}

/** Where thing `k` of `n` sits on the strip: the middle of its stretch. */
export function stripTick(k: number, width: number, n: number): number {
  const seg = Math.max(1, width - 2 * STRIP_PAD) / Math.max(1, n);
  return STRIP_PAD + seg * (k + 0.5);
}

/** 0.5, 1, 2.7: the way the Camera app writes zoom (".5" below 1). */
export function zoomText(z: number): string {
  if (z < 0.995) return `.${Math.round(z * 10)}`;
  const r = Math.round(z * 10) / 10;
  return Number.isInteger(r) ? `${r}` : r.toFixed(1);
}

/** Where a tap on the zoom button goes, in turn. */
export const ZOOM_STOPS = [0.5, 1, 2, 5];

/** The next stop up from `z` that the camera can do, or back round to the first. */
export function nextZoomStop(z: number, min: number, max: number): number {
  const stops = ZOOM_STOPS.filter((s) => s >= min - 1e-3 && s <= max + 1e-3);
  if (!stops.length) return Math.min(max, Math.max(min, z));
  return stops.find((s) => s > z + 0.05) ?? stops[0];
}

/**
 * The zoom a drag of `dx` points leads to from `from`: the dial's rim rolls under the finger,
 * `span` points of rim per e-fold of zoom. Dragging left zooms in, as on the Camera app's dial.
 */
export function zoomAfterDrag(from: number, dx: number, span: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, from * Math.exp(-dx / span)));
}

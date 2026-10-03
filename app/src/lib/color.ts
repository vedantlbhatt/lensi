/**
 * `rgba()` from a #RRGGBB colour and an alpha, safe to build every frame on the
 * UI thread. The alpha is clamped and rounded to three decimals: a tiny number
 * would otherwise print in exponent form ("rgba(255,255,255,9.4e-7)"), which
 * Reanimated's colour parser rejects by throwing, and in a Release build an
 * error thrown in a worklet aborts the app.
 */
export function rgba(hex: string, a: number): string {
  'worklet';
  const h = hex.replace('#', '');
  const full = h.length === 3 ? h[0] + h[0] + h[1] + h[1] + h[2] + h[2] : h;
  const n = parseInt(full.slice(0, 6), 16);
  const r = Number.isFinite(n) ? (n >> 16) & 255 : 0;
  const g = Number.isFinite(n) ? (n >> 8) & 255 : 0;
  const b = Number.isFinite(n) ? n & 255 : 0;
  const k = Math.round(Math.min(1, Math.max(0, Number.isFinite(a) ? a : 0)) * 1000) / 1000;
  return `rgba(${r},${g},${b},${k})`;
}

/** What a scripted run (a lensi:// link or the launch environment) can ask for. */
export type ScriptParams = {
  demo?: string;
  /** A photo or video in the app's Documents folder (CI drops stock footage there). */
  file?: string;
  lens?: string;
  ask?: string;
  memories?: string;
  export?: string;
  /** Force a brain for the run (CI demos use `vision`: its VM can't run Apple Intelligence). */
  brain?: string;
  /** Tap the print here once it's annotated, as `x,y` in 0–1 of the photo (CI films tap-to-ask). */
  tap?: string;
  /** Video: once the first moment is read, switch to this keyframe (0-based) and read it too. */
  moment?: string;
  /** Live guide: start a job with this task, as if it had been said (CI films the guide). */
  guide?: string;
  /** Virtual camera: show this demo scene (cars, truck, board, …). */
  scene?: string;
  /** Web preview: what the fake recogniser hears after the scene's question, lines split by `|` (films hands-free). */
  talk?: string;
  /** Take over-the-air updates in the Simulator too, and say which one is running (CI proves the path). */
  ota?: string;
  /** Turn the zoom dial to this zoom and leave it up, e.g. `2.7` (CI films the dial). */
  zoom?: string;
  /** Land a finger on the strip at the first of these (0–1 across it, comma-separated), slide through the rest and hold on the last: it pins that thing (CI films slide-to-pin). */
  scrub?: string;
};

/** `"0.3,0.33"` as a point on the photo, or null when it isn't one. */
export function pointOf(s: string | null | undefined): { x: number; y: number } | null {
  const [x, y] = (s ?? '').split(',').map((v) => Number(v.trim()));
  if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}

/** The query of a lensi:// URL, without leaning on URL.searchParams (not in every RN runtime). */
export function queryOf(url: string | null | undefined): ScriptParams {
  const out: Record<string, string> = {};
  const q = url?.split('?')[1]?.split('#')[0];
  for (const pair of q ? q.split('&') : []) {
    const [k, v = ''] = pair.split('=');
    if (!k) continue;
    try {
      out[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' '));
    } catch {
      // A malformed escape: keep it as typed rather than dropping the run.
      out[k] = v;
    }
  }
  return out;
}

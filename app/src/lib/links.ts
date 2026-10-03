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
};

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

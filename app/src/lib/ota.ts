import { reloadAppAsync } from 'expo';
import { Directory, File, Paths } from 'expo-file-system';
import { AppState, Platform } from 'react-native';

import { isVirtual, LensiAR } from '../../modules/lensi-ar/src';

/**
 * Over the air: JavaScript published since this build (tools/ota/publish.py puts each commit's
 * on the `ota` branch, per native runtime) is fetched at launch and run from the next start,
 * without a new install. Native changes need a new build: an update is only for the runtime
 * the app was built with (`LensiAR.runtime`, plugins/withOTA.js).
 *
 * Documents/ota/current holds the update that runs (main.jsbundle, its assets, update.json);
 * AppDelegate starts from it. `next` is a download in progress; `failed` one that never got
 * going (AppDelegate set it aside), not fetched again.
 */
const SOURCE = 'https://raw.githubusercontent.com/vedantlbhatt/lensi/ota/ios';

/** Which update this JavaScript is (CI stamps it at bundle time; `embedded` in a build's own). */
export const RUNNING_UPDATE = process.env.EXPO_PUBLIC_LENSI_UPDATE ?? 'dev';

type Part = { path: string; md5: string; bytes?: number };
export type Update = {
  id: string;
  runtime: string;
  createdAt: string;
  message?: string;
  /** Where its files are: base + path. */
  base: string;
  bundle: Part;
  assets: Part[];
};

const root = () => new Directory(Paths.document, 'ota');
const dir = (name: 'current' | 'next' | 'failed') => new Directory(root(), name);

function readUpdate(d: Directory): Update | null {
  try {
    const f = new File(d, 'update.json');
    return f.exists ? (JSON.parse(f.textSync()) as Update) : null;
  } catch {
    return null;
  }
}

let forced = false;
/** A scripted run (CI's `ota=1`) takes updates in the Simulator too, to prove the whole path. */
export function forceOTA() {
  forced = true;
}

/** Over the air only where it can run: a release build on an iPhone (or a scripted Simulator run). */
export function otaEnabled(): boolean {
  return !__DEV__ && Platform.OS === 'ios' && (forced || !isVirtual) && !!LensiAR.runtime && LensiAR.runtime !== 'none';
}

/** This JavaScript is running: AppDelegate's mark goes, so it isn't set aside next launch. */
export function confirmLaunch() {
  if (Platform.OS !== 'ios') return;
  try {
    const mark = new File(root(), 'launching');
    if (mark.exists) mark.delete();
  } catch {}
}

function md5Of(f: File): string | null {
  try {
    return f.info({ md5: true }).md5 ?? null;
  } catch {
    return null;
  }
}

/** One file of the update into `to`: copied from what runs now when it's the same, else downloaded and checked. */
async function fetchPart(update: Update, part: Part, to: Directory, have: Map<string, string>) {
  if (part.path.includes('..')) throw new Error(`bad path ${part.path}`);
  const dest = new File(to, part.path);
  dest.parentDirectory.create({ intermediates: true, idempotent: true });
  if (have.get(part.path) === part.md5) {
    const mine = new File(dir('current'), part.path);
    if (mine.exists) {
      mine.copySync(dest, { overwrite: true });
      return;
    }
  }
  const url = update.base + part.path.split('/').map(encodeURIComponent).join('/');
  const got = await File.downloadFileAsync(url, dest, { idempotent: true });
  if (md5Of(got) !== part.md5) throw new Error(`${part.path} came down damaged`);
}

/**
 * Looks for a newer update for this build and downloads it into place. Resolves the update
 * once it's ready to run (from the next start, or now via `applyUpdate`), else null.
 */
export async function checkForUpdate(): Promise<Update | null> {
  if (!otaEnabled()) return null;
  const res = await fetch(`${SOURCE}/${LensiAR.runtime}/update.json?t=${Date.now()}`, { cache: 'no-store' });
  if (!res.ok) return null;
  const update = (await res.json()) as Update;
  if (!update?.id || update.runtime !== LensiAR.runtime || update.id === RUNNING_UPDATE) return null;
  const current = readUpdate(dir('current'));
  if (current?.id === update.id) return update; // downloaded already: runs from the next start
  if (readUpdate(dir('failed'))?.id === update.id) return null;

  const next = dir('next');
  if (next.exists) next.delete();
  next.create({ intermediates: true });
  const have = new Map((current ? [current.bundle, ...current.assets] : []).map((p) => [p.path, p.md5]));
  await fetchPart(update, update.bundle, next, have);
  for (const a of update.assets) await fetchPart(update, a, next, have);
  new File(next, 'update.json').write(JSON.stringify(update));

  // Swap it in: what ran before goes.
  const cur = dir('current');
  if (cur.exists) cur.delete();
  next.rename('current');
  return update;
}

/** Restarts into the downloaded update now. */
export function applyUpdate() {
  void reloadAppAsync('Lensi update');
}

/** Restarts into it the next time the app goes to the background, so nothing in hand is lost. */
export function applyWhenAway() {
  const sub = AppState.addEventListener('change', (s) => {
    if (s !== 'background') return;
    sub.remove();
    applyUpdate();
  });
}

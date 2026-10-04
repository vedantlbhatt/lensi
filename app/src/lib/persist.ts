import { Directory, File, Paths } from 'expo-file-system';
import { Platform } from 'react-native';

/**
 * Everything Lensi keeps lives under Documents/lensi. On the web preview there
 * is no durable file system worth using, so persistence quietly becomes a no-op
 * and state lives in memory for the session.
 */
export const canPersist = Platform.OS !== 'web';

export function rootDir(): Directory | null {
  if (!canPersist) return null;
  const dir = new Directory(Paths.document, 'lensi');
  if (!dir.exists) dir.create({ intermediates: true, idempotent: true });
  return dir;
}

export function captureDir(id: string): Directory | null {
  const root = rootDir();
  if (!root) return null;
  const dir = new Directory(root, 'captures', id);
  if (!dir.exists) dir.create({ intermediates: true, idempotent: true });
  return dir;
}

/** A file inside the app's data folder, or null where nothing persists. */
export function dataFile(...parts: string[]): File | null {
  const root = rootDir();
  return root ? new File(root, ...parts) : null;
}

export function readJSON<T>(file: File | null): T | null {
  if (!file) return null;
  try {
    if (!file.exists) return null;
    return JSON.parse(file.textSync()) as T;
  } catch {
    return null;
  }
}

export function writeJSON(file: File | null, value: unknown) {
  if (!canPersist || !file) return;
  try {
    file.write(JSON.stringify(value));
  } catch (e) {
    console.warn('[lensi] could not save', file.uri, e);
  }
}

/** Copies a file into `dir` as `name` and returns the durable URI. */
export async function keep(uri: string, dir: Directory | null, name: string): Promise<string> {
  if (!canPersist || !dir || !uri.startsWith('file:')) return uri;
  const target = new File(dir, name);
  try {
    if (target.exists) target.delete();
    await new File(uri).copy(target);
    return target.uri;
  } catch (e) {
    console.warn('[lensi] could not keep', uri, e);
    return uri;
  }
}

export function debounce<A extends unknown[]>(fn: (...a: A) => void, ms: number) {
  let t: ReturnType<typeof setTimeout> | null = null;
  return (...a: A) => {
    if (t) clearTimeout(t);
    t = setTimeout(() => {
      t = null;
      fn(...a);
    }, ms);
  };
}

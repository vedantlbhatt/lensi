import { Directory, File } from 'expo-file-system';
import { useSyncExternalStore } from 'react';

import { canPersist, captureDir, debounce, readJSON, rootDir, writeJSON } from './persist';
import type { Capture } from './types';

type State = { byId: Record<string, Capture>; order: string[]; loaded: boolean };

let state: State = { byId: {}, order: [], loaded: false };
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());
const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => listeners.delete(l);
};

const savers = new Map<string, () => void>();
function save(id: string) {
  if (!canPersist) return;
  let s = savers.get(id);
  if (!s) {
    s = debounce(() => {
      const c = state.byId[id];
      const dir = captureDir(id);
      if (c && dir) writeJSON(new File(dir, 'capture.json'), c);
    }, 350);
    savers.set(id, s);
  }
  s();
}

/** Reads every saved capture once at startup. Cheap: one small JSON each. */
export function loadCaptures() {
  if (state.loaded) return;
  const byId: Record<string, Capture> = {};
  if (canPersist) {
    try {
      const root = rootDir();
      const captures = root ? new Directory(root, 'captures') : null;
      if (captures?.exists) {
        for (const entry of captures.list()) {
          if (!(entry instanceof Directory)) continue;
          const c = readJSON<Capture>(new File(entry, 'capture.json'));
          if (!c?.id) continue;
          // Anything still "analyzing" was interrupted by a quit; keep what landed.
          byId[c.id] = c.status === 'analyzing' ? { ...c, status: 'ready' } : c;
        }
      }
    } catch (e) {
      console.warn('[lensi] could not load memories', e);
    }
  }
  const order = Object.values(byId)
    .sort((a, b) => b.createdAt - a.createdAt)
    .map((c) => c.id);
  state = { byId, order, loaded: true };
  emit();
}

export function getCapture(id: string): Capture | undefined {
  return state.byId[id];
}

export function addCapture(c: Capture) {
  state = { ...state, byId: { ...state.byId, [c.id]: c }, order: [c.id, ...state.order.filter((x) => x !== c.id)] };
  save(c.id);
  emit();
}

export function patchCapture(id: string, fn: (c: Capture) => Capture) {
  const cur = state.byId[id];
  if (!cur) return;
  const next = fn(cur);
  if (next === cur) return;
  state = { ...state, byId: { ...state.byId, [id]: next } };
  save(id);
  emit();
}

export function removeCapture(id: string) {
  if (!state.byId[id]) return;
  const { [id]: _gone, ...rest } = state.byId;
  state = { ...state, byId: rest, order: state.order.filter((x) => x !== id) };
  if (canPersist) {
    try {
      captureDir(id)?.delete();
    } catch {}
  }
  emit();
}

/** Every capture, gone from memory and from disk. */
export function clearCaptures() {
  const ids = [...state.order];
  state = { ...state, byId: {}, order: [] };
  if (canPersist) {
    for (const id of ids) {
      try {
        captureDir(id)?.delete();
      } catch {}
    }
  }
  emit();
}

const getState = () => state;

export function useCaptureList(): Capture[] {
  const s = useSyncExternalStore(subscribe, getState, getState);
  return s.order.map((id) => s.byId[id]).filter(Boolean);
}

export function useCapture(id: string | null): Capture | null {
  const s = useSyncExternalStore(subscribe, getState, getState);
  return id ? (s.byId[id] ?? null) : null;
}

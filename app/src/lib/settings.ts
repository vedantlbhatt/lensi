import { useSyncExternalStore } from 'react';

import type { Lens } from '../theme/tokens';
import { canPersist, dataFile, readJSON, writeJSON } from './persist';

export type Brain = 'auto' | 'apple' | 'cloud' | 'vision';

export type Settings = {
  /** Which model answers. Auto prefers on-device Apple Intelligence. */
  brain: Brain;
  /** Read walkthrough steps out loud. */
  narrate: boolean;
  haptics: boolean;
  /** Draw live detection brackets on the camera. */
  liveBrackets: boolean;
  /** Override for the cloud server; empty means the dev machine / env. */
  serverURL: string;
  /** The lens the camera opens on: whatever was used last. */
  lens: Lens;
};

const DEFAULTS: Settings = { brain: 'auto', narrate: true, haptics: true, liveBrackets: true, serverURL: '', lens: 'guide' };

let state: Settings = DEFAULTS;
let loaded = false;
const listeners = new Set<() => void>();
const file = () => dataFile('settings.json');

function load() {
  if (loaded) return;
  loaded = true;
  if (!canPersist) return;
  const saved = readJSON<Partial<Settings>>(file());
  if (saved) state = { ...DEFAULTS, ...saved };
}

export function getSettings(): Settings {
  load();
  return state;
}

export function setSettings(patch: Partial<Settings>) {
  load();
  state = { ...state, ...patch };
  writeJSON(file(), state);
  listeners.forEach((l) => l());
}

export function useSettings(): Settings {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    getSettings,
    getSettings,
  );
}

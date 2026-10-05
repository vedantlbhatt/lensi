import { useSyncExternalStore } from 'react';

import type { LiveStats } from '../../modules/lensi-ar/src';

/**
 * How EdgeTAM last said it runs on this phone (LensiARView's onLiveStats, every few seconds while
 * something's pinned): Settings shows it, so a build without a terminal still says how fast it is.
 */
let latest: LiveStats | null = null;
const listeners = new Set<() => void>();

export function setLiveStats(s: LiveStats) {
  latest = s;
  for (const l of listeners) l();
}

export function useLiveStats(): LiveStats | null {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => {
        listeners.delete(l);
      };
    },
    () => latest,
  );
}

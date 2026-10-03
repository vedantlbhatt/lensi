import { useRef } from 'react';

/**
 * Entrance order for a list that grows while you watch (callouts arrive as the
 * model names them) and shrinks when you edit it. The first batch cascades by
 * index; anything that arrives later goes first in line, so it shows up when
 * it's named instead of queueing behind labels already on screen. A list whose
 * ids are all new (another photo, another lens) counts as a first batch again.
 */
export function useArrivalOrder(ids: readonly string[], batchMs = 250): (i: number) => number {
  const born = useRef<number | null>(null);
  const prev = useRef<readonly string[]>([]);
  if (!ids.length) born.current = null;
  else if (born.current === null || !ids.some((id) => prev.current.includes(id))) born.current = Date.now();
  prev.current = ids;
  const late = born.current !== null && Date.now() - born.current > batchMs;
  return (i) => (late ? 0 : i);
}

/**
 * The value a component mounted with. Entrance delays go through this so that
 * removing or restoring one item never replays the entrances of the rest.
 */
export function useMountValue<T>(value: T): T {
  return useRef(value).current;
}

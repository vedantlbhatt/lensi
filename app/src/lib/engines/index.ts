import type { Brain } from '../settings';
import type { Engine } from '../types';
import { appleEngine } from './apple';
import { cloudEngine } from './cloud';
import { visionEngine } from './vision';

export { appleEngine, cloudEngine, visionEngine };

/** Auto: on-device Apple Intelligence, then the cloud, then vision only. */
export async function pickEngine(brain: Brain): Promise<Engine> {
  const order: Engine[] =
    brain === 'apple'
      ? [appleEngine, visionEngine]
      : brain === 'cloud'
        ? [cloudEngine, visionEngine]
        : brain === 'vision'
          ? [visionEngine]
          : [appleEngine, cloudEngine, visionEngine];
  for (const e of order) {
    if (await e.available()) return e;
  }
  return visionEngine;
}

import * as Haptics from 'expo-haptics';

import { getSettings } from './settings';

/**
 * The app's haptic vocabulary, all gated by the Haptics setting:
 * tick = a label landing, tap = the pointer arriving, thud = a capture or a
 * step change, done = a walkthrough finished.
 */
export const haptic = {
  tick() {
    if (getSettings().haptics) Haptics.selectionAsync().catch(() => {});
  },
  tap() {
    if (getSettings().haptics) Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {});
  },
  thud() {
    if (getSettings().haptics) Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
  },
  done() {
    if (getSettings().haptics) Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
  },
};

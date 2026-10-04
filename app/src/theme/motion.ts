import { Easing, type WithSpringConfig } from 'react-native-reanimated';

/**
 * Motion vocabulary. Nothing bounces: every spring is critically damped and
 * clamped at its target, so things arrive and stop. Names describe intent.
 */
export const springs = {
  /** Buttons settling after a press. */
  press: { damping: 34, stiffness: 420, mass: 0.6, overshootClamping: true },
  /** Things arriving: sheets, cards, pills. */
  arrive: { damping: 30, stiffness: 210, mass: 0.9, overshootClamping: true },
  /** Marks that land on the world. */
  pop: { damping: 30, stiffness: 300, mass: 0.7, overshootClamping: true },
  /** Heavy, deliberate travel: the pointer flying between targets. */
  travel: { damping: 24, stiffness: 120, mass: 1.1, overshootClamping: true },
  /** Gentle follow, e.g. magnetic buttons tracking a finger. */
  follow: { damping: 20, stiffness: 180, mass: 0.5, overshootClamping: true },
  /** Snappy UI toggles. */
  snap: { damping: 40, stiffness: 520, mass: 0.7, overshootClamping: true },
} satisfies Record<string, WithSpringConfig>;

/** Inline spring settings get the same treatment: no overshoot, ever. */
export const calm = (c: { damping?: number; stiffness?: number; mass?: number }): WithSpringConfig => ({
  stiffness: c.stiffness ?? 200,
  mass: c.mass ?? 1,
  damping: Math.max(c.damping ?? 0, 24),
  overshootClamping: true,
});

export const curves = {
  /** Draw-on strokes: fast start, long settle. */
  draw: Easing.bezier(0.16, 1, 0.3, 1),
  /** Fades out of the way. */
  exit: Easing.bezier(0.4, 0, 1, 1),
  /** Standard ease for opacity. */
  ease: Easing.bezier(0.25, 0.1, 0.25, 1),
  /** Leaving: eases in (no dip back first). */
  anticipate: Easing.bezier(0.4, 0, 1, 1),
};

export const durations = { tick: 120, quick: 200, base: 320, slow: 560, draw: 900 } as const;

/** Per-item stagger for choreographed reveals. */
export const stagger = (i: number, step = 55, base = 0) => base + i * step;

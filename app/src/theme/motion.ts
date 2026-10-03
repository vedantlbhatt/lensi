import { Easing, type WithSpringConfig } from 'react-native-reanimated';

/**
 * Motion vocabulary. Everything physical is a spring; only opacity and
 * strokes that "draw" use timing curves. Names describe intent, not numbers.
 */
export const springs = {
  /** Buttons settling after a press. Quick, a single overshoot. */
  press: { damping: 14, stiffness: 420, mass: 0.6 },
  /** Things arriving: sheets, cards, pills. */
  arrive: { damping: 20, stiffness: 210, mass: 0.9 },
  /** Playful pop for marks that land on the world. */
  pop: { damping: 11, stiffness: 300, mass: 0.7 },
  /** Heavy, deliberate travel: the pointer flying between targets. */
  travel: { damping: 22, stiffness: 120, mass: 1.1 },
  /** Gentle follow, e.g. magnetic buttons tracking a finger. */
  follow: { damping: 18, stiffness: 180, mass: 0.5 },
  /** Snappy UI toggles. */
  snap: { damping: 26, stiffness: 520, mass: 0.7 },
} satisfies Record<string, WithSpringConfig>;

export const curves = {
  /** Draw-on strokes: fast start, long settle. */
  draw: Easing.bezier(0.16, 1, 0.3, 1),
  /** Fades out of the way. */
  exit: Easing.bezier(0.4, 0, 1, 1),
  /** Standard ease for opacity. */
  ease: Easing.bezier(0.25, 0.1, 0.25, 1),
  /** Anticipation: dips back before going. */
  anticipate: Easing.bezier(0.36, 0, 0.66, -0.56),
};

export const durations = { tick: 120, quick: 200, base: 320, slow: 560, draw: 900 } as const;

/** Per-item stagger for choreographed reveals. */
export const stagger = (i: number, step = 55, base = 0) => base + i * step;

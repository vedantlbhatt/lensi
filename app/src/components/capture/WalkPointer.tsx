import { useEffect, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, {
  Easing,
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withRepeat,
  withSequence,
  withSpring,
  withTiming,
} from 'react-native-reanimated';
import Svg, { Path } from 'react-native-svg';

import { arcControl, quadAt } from '../../lib/geometry';
import { haptic } from '../../lib/haptics';
import type { Pt } from '../../lib/types';
import { Ripple } from '../../motion/Ripple';
import { ink } from '../../theme/tokens';

const W = 30;
const H = 36;

/**
 * The walkthrough's hand: a chunky cursor that arcs from one target to the
 * next like something tossed, leans into the turn, taps when it lands, and
 * bobs while it waits. The tip is the exact target point.
 */
export function WalkPointer({
  target,
  index,
  pen,
  home,
}: {
  target: Pt | null;
  index: number;
  pen: string;
  home: Pt;
}) {
  const from = useSharedValue<Pt>(home);
  const to = useSharedValue<Pt>(home);
  const ctrl = useSharedValue<Pt>(home);
  const t = useSharedValue(1);
  const tap = useSharedValue(0);
  const bob = useSharedValue(0);
  const shown = useSharedValue(0);
  const last = useRef<Pt>(home);
  const [landedKey, setLandedKey] = useState<string | null>(null);

  useEffect(() => {
    bob.value = withRepeat(withTiming(1, { duration: 1100, easing: Easing.inOut(Easing.sin) }), -1, true);
  }, [bob]);

  // Keyed on the numbers, not the object: a re-render with the same target
  // must not throw the pointer again.
  const tx = target?.x ?? null;
  const ty = target?.y ?? null;
  const homeRef = useRef(home);
  homeRef.current = home;
  useEffect(() => {
    if (tx === null || ty === null) {
      shown.value = withTiming(0, { duration: 200 });
      // Next time, fly out from the card again.
      last.current = homeRef.current;
      return;
    }
    const goal = { x: tx, y: ty };
    shown.value = withSpring(1, { damping: 16, stiffness: 220 });
    const a = last.current;
    from.value = a;
    to.value = goal;
    ctrl.value = arcControl(a, goal, 0.32);
    t.value = 0;
    const d = Math.hypot(goal.x - a.x, goal.y - a.y);
    const duration = Math.min(900, Math.max(420, d * 1.5));
    t.value = withTiming(1, { duration, easing: Easing.bezier(0.45, 0, 0.2, 1) });
    tap.value = withDelay(duration - 40, withSequence(withTiming(1, { duration: 110 }), withSpring(0, { damping: 9, stiffness: 300 })));
    last.current = goal;
    const k = `${index}-${goal.x.toFixed(1)}-${goal.y.toFixed(1)}`;
    const h = setTimeout(() => {
      setLandedKey(k);
      haptic.tap();
    }, duration);
    return () => clearTimeout(h);
  }, [tx, ty, index, from, to, ctrl, t, tap, shown]);

  const a = useAnimatedStyle(() => {
    const p = quadAt(from.value, ctrl.value, to.value, t.value);
    // Lean into travel direction; settle upright when done.
    const dx = to.value.x - from.value.x;
    const travelling = t.value < 1 ? Math.sin(t.value * Math.PI) : 0;
    const lean = Math.max(-1, Math.min(1, dx / 220)) * 22 * travelling;
    const idle = t.value >= 1 ? (bob.value - 0.5) * 4 : 0;
    return {
      opacity: shown.value,
      transform: [
        { translateX: p.x },
        { translateY: p.y + idle },
        { rotate: `${-14 + lean}deg` },
        { scale: (0.6 + shown.value * 0.4) * (1 - tap.value * 0.16) },
      ],
    };
  });

  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      {landedKey && target ? (
        <View key={landedKey} style={[styles.rippleAt, { left: target.x, top: target.y }]}>
          <Ripple size={20} color={pen} duration={760} grow={3.2} stroke={2.4} />
        </View>
      ) : null}
      <Animated.View style={[styles.pointer, a]}>
        <Svg width={W} height={H} viewBox="0 0 30 36" style={styles.svg}>
          <Path
            d="M3.2 2.6c0-1.2 1.4-1.9 2.3-1.1l20.1 17.1c.9.8.4 2.3-.8 2.4l-8.4.6 4.6 9.9c.4.8 0 1.7-.8 2.1l-3.1 1.4c-.8.4-1.7 0-2.1-.8l-4.5-9.8-5.9 6.1c-.8.9-2.3.3-2.3-.9L3.2 2.6z"
            fill={pen}
            stroke={ink}
            strokeWidth={1.7}
            strokeLinejoin="round"
          />
          <Path d="M6.2 6.4l1.1 17.4" stroke="rgba(255,255,255,0.65)" strokeWidth={1.6} strokeLinecap="round" />
        </Svg>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  pointer: {
    position: 'absolute',
    left: 0,
    top: 0,
    width: W,
    height: H,
    transformOrigin: 'left top',
    shadowColor: '#000',
    shadowOpacity: 0.45,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 5 },
  },
  svg: { position: 'absolute', left: -3, top: -2 },
  rippleAt: { position: 'absolute', width: 0, height: 0 },
});

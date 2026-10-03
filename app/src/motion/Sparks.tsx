import { forwardRef, useCallback, useEffect, useImperativeHandle, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, { Easing, useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';

export type SparksRef = { burst(x: number, y: number, color?: string): void };

type Burst = { id: number; x: number; y: number; color: string };

/**
 * Short strokes fly out of a point and vanish (after React Bits' ClickSpark).
 * Mount once, full-screen, `pointerEvents="none"`; call `burst()` from taps.
 */
export const Sparks = forwardRef<SparksRef, { count?: number; radius?: number; color?: string }>(function Sparks(
  { count = 9, radius = 34, color = '#FFFFFF' },
  ref,
) {
  const [bursts, setBursts] = useState<Burst[]>([]);
  const done = useCallback((id: number) => setBursts((b) => b.filter((x) => x.id !== id)), []);
  useImperativeHandle(ref, () => ({
    burst: (x, y, c) => setBursts((b) => [...b.slice(-4), { id: Date.now() + Math.random(), x, y, color: c ?? color }]),
  }));
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      {bursts.map((b) => (
        <BurstView key={b.id} burst={b} count={count} radius={radius} onDone={done} />
      ))}
    </View>
  );
});

function BurstView({ burst, count, radius, onDone }: { burst: Burst; count: number; radius: number; onDone: (id: number) => void }) {
  return (
    <View style={[styles.origin, { left: burst.x, top: burst.y }]}>
      {Array.from({ length: count }, (_, i) => (
        <Spark key={i} angle={(i / count) * Math.PI * 2 + 0.3} radius={radius} color={burst.color} last={i === count - 1} onDone={() => onDone(burst.id)} />
      ))}
    </View>
  );
}

function Spark({ angle, radius, color, last, onDone }: { angle: number; radius: number; color: string; last: boolean; onDone: () => void }) {
  const t = useSharedValue(0);
  useEffect(() => {
    t.value = withTiming(1, { duration: 520, easing: Easing.out(Easing.cubic) });
    if (!last) return;
    const done = setTimeout(onDone, 600);
    return () => clearTimeout(done);
    // Mount-only: a spark lives exactly one burst.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const a = useAnimatedStyle(() => {
    const d = 8 + t.value * radius;
    const len = 10 * (1 - t.value) + 2;
    return {
      opacity: 1 - t.value,
      width: len,
      transform: [{ rotate: `${angle}rad` }, { translateX: d }],
    };
  });
  return <Animated.View style={[styles.spark, { backgroundColor: color }, a]} />;
}

const styles = StyleSheet.create({
  origin: { position: 'absolute', width: 0, height: 0 },
  spark: { position: 'absolute', height: 2.2, borderRadius: 2, left: 0, top: -1.1 },
});


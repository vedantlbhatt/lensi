import { useEffect } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { Easing, FadeOut, useAnimatedStyle, useSharedValue, withDelay, withSpring, withTiming } from 'react-native-reanimated';

import { haptic } from '../../lib/haptics';
import { useArrivalOrder, useMountValue } from '../../motion/stagger';
import { springs } from '../../theme/motion';
import { face } from '../../theme/type';
import { LABEL, labelText, type PlacedCallout } from './layout';

/**
 * The names, written on the things themselves: a plain white tag centred on
 * each part. Tapping one asks about that part; holding one opens its menu.
 */
export function CalloutLabels({
  placed,
  dim,
  focusId,
  onPress,
  onLongPress,
}: {
  placed: PlacedCallout[];
  dim: boolean;
  /** One label being edited: the others step back. */
  focusId?: string | null;
  onPress?: (c: PlacedCallout) => void;
  onLongPress?: (c: PlacedCallout) => void;
}) {
  const order = useArrivalOrder(placed.map((c) => c.id));
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="box-none">
      {placed.map((c, i) => (
        <Tag
          key={c.id}
          c={c}
          delay={order(i) * 110 + 300}
          dim={dim || (!!focusId && focusId !== c.id)}
          lifted={focusId === c.id}
          onPress={onPress}
          onLongPress={onLongPress}
        />
      ))}
    </View>
  );
}

function Tag({
  c,
  delay,
  dim,
  lifted,
  onPress,
  onLongPress,
}: {
  c: PlacedCallout;
  delay: number;
  dim: boolean;
  lifted: boolean;
  onPress?: (c: PlacedCallout) => void;
  onLongPress?: (c: PlacedCallout) => void;
}) {
  const entry = useMountValue(delay);
  const t = useSharedValue(0);
  const d = useSharedValue(1);
  const lift = useSharedValue(0);
  useEffect(() => {
    lift.value = withSpring(lifted ? 1 : 0, springs.pop);
  }, [lifted, lift]);
  useEffect(() => {
    t.value = withDelay(entry, withSpring(1, springs.arrive));
    const h = setTimeout(haptic.tick, entry + 60);
    return () => clearTimeout(h);
  }, [entry, t]);
  useEffect(() => {
    d.value = withTiming(dim ? 0.18 : 1, { duration: 320, easing: Easing.out(Easing.quad) });
  }, [dim, d]);
  const a = useAnimatedStyle(() => ({
    opacity: Math.min(1, t.value * 1.4) * d.value,
    transform: [{ translateY: (1 - t.value) * 6 }, { scale: (0.88 + t.value * 0.12) * (1 + lift.value * 0.08) }],
  }));
  return (
    <Animated.View
      style={[styles.slot, { left: c.slot.x, top: c.slot.y, width: c.width }, a]}
      exiting={FadeOut.duration(160)}
      pointerEvents="box-none"
    >
      <Pressable
        onPress={() => onPress?.(c)}
        onLongPress={onLongPress ? () => onLongPress(c) : undefined}
        delayLongPress={360}
        hitSlop={6}
        accessibilityRole="button"
        accessibilityLabel={`${c.label}. Ask about it.`}
        accessibilityHint={onLongPress ? 'Hold to rename or remove' : undefined}
        style={styles.tag}
      >
        <Text style={styles.text} numberOfLines={1}>
          {labelText(c.label)}
        </Text>
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  slot: { position: 'absolute', height: LABEL.height, alignItems: 'center', justifyContent: 'center' },
  tag: {
    height: LABEL.height,
    maxWidth: '100%',
    paddingHorizontal: LABEL.padX,
    borderRadius: 7,
    borderCurve: 'continuous',
    justifyContent: 'center',
    backgroundColor: '#FFFFFF',
    shadowColor: '#000',
    shadowOpacity: 0.28,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 },
  },
  text: { color: '#000000', ...face.semibold, fontSize: LABEL.size, letterSpacing: -0.08 },
});

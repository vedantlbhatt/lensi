import { Pressable, StyleSheet, View } from 'react-native';
import Animated, { Easing, useAnimatedStyle, useSharedValue, withDelay, withSpring, withTiming, ZoomOut } from 'react-native-reanimated';
import { useEffect } from 'react';

import { haptic } from '../../lib/haptics';
import { DecryptedText } from '../../motion/DecryptedText';
import { useArrivalOrder, useMountValue } from '../../motion/stagger';
import { springs } from '../../theme/motion';
import { paper } from '../../theme/tokens';
import { LABEL, labelText, type PlacedCallout } from './layout';

/**
 * Label pills for callouts. Each one unfolds from the end of its leader line
 * (so it reads as growing out of the dot) and its text decrypts in. Tapping a
 * label asks about that part; holding one opens its menu.
 */
export function CalloutLabels({
  placed,
  pen,
  dim,
  focusId,
  onPress,
  onLongPress,
}: {
  placed: PlacedCallout[];
  pen: string;
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
        <Label
          key={c.id}
          c={c}
          pen={pen}
          delay={order(i) * 110 + 380}
          dim={dim || (!!focusId && focusId !== c.id)}
          lifted={focusId === c.id}
          onPress={onPress}
          onLongPress={onLongPress}
        />
      ))}
    </View>
  );
}

function Label({
  c,
  pen,
  delay,
  dim,
  lifted,
  onPress,
  onLongPress,
}: {
  c: PlacedCallout;
  pen: string;
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
  const fromLeft = c.slot.side === 1;
  const a = useAnimatedStyle(() => ({
    opacity: Math.min(1, t.value * 1.4) * d.value,
    transform: [
      { translateX: (1 - t.value) * (fromLeft ? -14 : 14) },
      { scaleX: (0.35 + t.value * 0.65) * (1 + lift.value * 0.08) },
      { scaleY: (0.7 + t.value * 0.3) * (1 + lift.value * 0.08) },
    ],
  }));
  return (
    <Animated.View
      style={[
        styles.pill,
        { left: c.slot.x, top: c.slot.y, width: c.width, transformOrigin: fromLeft ? 'left center' : 'right center' },
        a,
      ]}
      exiting={ZoomOut.duration(200)}
    >
      <Pressable
        onPress={() => onPress?.(c)}
        onLongPress={onLongPress ? () => onLongPress(c) : undefined}
        delayLongPress={360}
        hitSlop={6}
        accessibilityRole="button"
        accessibilityLabel={`${c.label}. Ask about it.`}
        accessibilityHint={onLongPress ? 'Hold to rename or remove' : undefined}
        style={styles.row}
      >
        <View style={[styles.dot, { backgroundColor: pen }]} />
        <DecryptedText text={labelText(c.label)} delay={entry + 90} style={styles.text} speed={24} scrambles={3} numberOfLines={1} />
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  pill: {
    position: 'absolute',
    height: LABEL.height,
    borderRadius: 9,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(11,11,12,0.84)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(244,241,234,0.22)',
    shadowColor: '#000',
    shadowOpacity: 0.3,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 4 },
  },
  row: { flex: 1, flexDirection: 'row', alignItems: 'center', paddingHorizontal: LABEL.padX, gap: LABEL.gap },
  dot: { width: LABEL.dot, height: LABEL.dot, borderRadius: LABEL.dot / 2 },
  text: { color: paper, fontFamily: LABEL.font, fontSize: LABEL.size, letterSpacing: LABEL.letter },
});

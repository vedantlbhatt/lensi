import * as Haptics from 'expo-haptics';
import { useEffect, useRef } from 'react';
import { Pressable, StyleSheet, useWindowDimensions, View } from 'react-native';
import Animated, {
  interpolate,
  interpolateColor,
  useAnimatedRef,
  useAnimatedScrollHandler,
  useAnimatedStyle,
  useSharedValue,
  scrollTo,
  type SharedValue,
} from 'react-native-reanimated';
import { scheduleOnRN, scheduleOnUI } from 'react-native-worklets';

import { getSettings } from '../../lib/settings';
import { LENSES, paper, type Lens } from '../../theme/tokens';
import { fonts } from '../../theme/type';

const ITEM = 92;

/**
 * Lens names on a wheel above the shutter. Swipe or tap; the centred name
 * grows, takes its pen colour, and the shutter disc follows.
 */
export function LensCarousel({ lens, onChange }: { lens: Lens; onChange: (l: Lens) => void }) {
  const { width } = useWindowDimensions();
  const ref = useAnimatedRef<Animated.ScrollView>();
  const initialX = useRef(LENSES.findIndex((l) => l.key === lens) * ITEM).current;
  const x = useSharedValue(initialX);
  const lastIndex = useRef(LENSES.findIndex((l) => l.key === lens));
  const pad = (width - ITEM) / 2;

  const tick = (i: number) => {
    if (i === lastIndex.current) return;
    lastIndex.current = i;
    if (getSettings().haptics) Haptics.selectionAsync().catch(() => {});
  };
  const settle = (i: number) => {
    const l = LENSES[Math.max(0, Math.min(LENSES.length - 1, i))];
    if (l && l.key !== lens) onChange(l.key);
  };

  const onScroll = useAnimatedScrollHandler({
    onScroll: (e) => {
      x.value = e.contentOffset.x;
      scheduleOnRN(tick, Math.round(e.contentOffset.x / ITEM));
    },
    onMomentumEnd: (e) => {
      scheduleOnRN(settle, Math.round(e.contentOffset.x / ITEM));
    },
  });

  // Follow external changes (e.g. swiping across the camera).
  useEffect(() => {
    const i = LENSES.findIndex((l) => l.key === lens);
    if (Math.round(x.value / ITEM) !== i) {
      scheduleOnUI(() => {
        'worklet';
        scrollTo(ref, i * ITEM, 0, true);
      });
    }
  }, [lens, ref, x]);

  return (
    <View style={styles.wrap} pointerEvents="box-none">
      <Animated.ScrollView
        ref={ref}
        horizontal
        showsHorizontalScrollIndicator={false}
        snapToInterval={ITEM}
        decelerationRate="fast"
        onScroll={onScroll}
        scrollEventThrottle={16}
        contentOffset={{ x: initialX, y: 0 }}
        contentContainerStyle={{ paddingHorizontal: pad }}
        style={styles.scroll}
      >
        {LENSES.map((l, i) => (
          <Item
            key={l.key}
            name={l.name}
            pen={l.pen}
            index={i}
            x={x}
            onPress={() => {
              scheduleOnUI(() => {
                'worklet';
                scrollTo(ref, i * ITEM, 0, true);
              });
              onChange(l.key);
            }}
          />
        ))}
      </Animated.ScrollView>
      <Notch x={x} />
    </View>
  );
}

function Item({ name, pen, index, x, onPress }: { name: string; pen: string; index: number; x: SharedValue<number>; onPress: () => void }) {
  const a = useAnimatedStyle(() => {
    const d = Math.abs(x.value / ITEM - index);
    return {
      opacity: interpolate(d, [0, 1, 2.5], [1, 0.62, 0.28], 'clamp'),
      transform: [{ scale: interpolate(d, [0, 1], [1.14, 0.9], 'clamp') }, { translateY: interpolate(d, [0, 1], [0, 2], 'clamp') }],
    };
  });
  const t = useAnimatedStyle(() => {
    const d = Math.abs(x.value / ITEM - index);
    return { color: interpolateColor(Math.min(d, 1), [0, 1], [pen, paper]) };
  });
  return (
    <Pressable onPress={onPress} hitSlop={6} accessibilityRole="button" accessibilityLabel={`${name} lens`}>
      <Animated.View style={[styles.item, a]}>
        <Animated.Text style={[styles.text, t]} numberOfLines={1}>
          {name}
        </Animated.Text>
      </Animated.View>
    </Pressable>
  );
}

/** The little tick under the centred lens; stretches while you swipe. */
function Notch({ x }: { x: SharedValue<number> }) {
  const a = useAnimatedStyle(() => {
    const off = Math.abs(x.value / ITEM - Math.round(x.value / ITEM));
    return { width: 6 + off * 26, opacity: 1 - off * 0.5 };
  });
  return <Animated.View style={[styles.notch, a]} pointerEvents="none" />;
}

const styles = StyleSheet.create({
  wrap: { height: 44, alignSelf: 'stretch', justifyContent: 'center' },
  scroll: { flexGrow: 0 },
  item: { width: ITEM, height: 34, alignItems: 'center', justifyContent: 'center' },
  text: {
    fontFamily: fonts.displayBold,
    fontSize: 16,
    letterSpacing: -0.2,
    textShadowColor: 'rgba(0,0,0,0.45)',
    textShadowRadius: 8,
    textShadowOffset: { width: 0, height: 1 },
  },
  notch: { position: 'absolute', bottom: 0, alignSelf: 'center', height: 3, borderRadius: 2, backgroundColor: paper },
});

import { useRef } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeInLeft } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { hairline, ink, LENSES, paper, type Lens } from '../../theme/tokens';
import { fonts } from '../../theme/type';

/**
 * The six pens, fanned out of the capture's lens chip. Picking another one
 * redraws the photo through that lens; picking the current one folds it away.
 */
export function LensPicker({ lens, onPick }: { lens: Lens; onPick: (l: Lens) => void }) {
  const scroll = useRef<ScrollView>(null);
  return (
    <ScrollView ref={scroll} horizontal showsHorizontalScrollIndicator={false} style={styles.scroll} contentContainerStyle={styles.row}>
      {LENSES.map((l, i) => {
        const on = l.key === lens;
        return (
          <Animated.View
            key={l.key}
            entering={FadeInLeft.delay(i * 32).springify().damping(17).stiffness(260)}
            // Open with the current lens in view, even when it's one of the last.
            onLayout={on && i > 2 ? (e) => scroll.current?.scrollTo({ x: Math.max(0, e.nativeEvent.layout.x - 60), animated: false }) : undefined}
          >
            <PressScale
              onPress={() => onPick(l.key)}
              scaleTo={0.9}
              haptic="selection"
              accessibilityRole="button"
              accessibilityState={{ selected: on }}
              accessibilityLabel={on ? `${l.name}, current lens` : `Look again with ${l.name}`}
            >
              <View style={[styles.opt, on && { backgroundColor: l.pen, borderColor: l.pen }]}>
                <View style={[styles.dot, { backgroundColor: on ? ink : l.pen }]} />
                <Text style={[styles.text, on && { color: ink }]}>{l.name.toUpperCase()}</Text>
              </View>
            </PressScale>
          </Animated.View>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flexGrow: 0, marginHorizontal: -18 },
  row: { flexDirection: 'row', gap: 6, paddingHorizontal: 18 },
  opt: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    height: 26,
    paddingHorizontal: 10,
    borderRadius: 13,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
  },
  dot: { width: 7, height: 7, borderRadius: 4 },
  text: { color: paper, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.2 },
});

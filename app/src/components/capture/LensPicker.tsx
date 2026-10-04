import { useRef } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeInLeft } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { hairline, ink, LENSES, paper, type Lens } from '../../theme/tokens';
import { face } from '../../theme/type';

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
            entering={FadeInLeft.delay(i * 32).duration(240)}
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
                <Text style={[styles.text, { color: on ? ink : l.pen }]}>{l.name}</Text>
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
    height: 28,
    paddingHorizontal: 11,
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
  },
  text: { color: paper, ...face.semibold, fontSize: 13 },
});

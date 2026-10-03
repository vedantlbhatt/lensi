import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeOut, ZoomIn } from 'react-native-reanimated';

import { DecryptedText } from '../../motion/DecryptedText';
import { faint, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Glass } from './Glass';

/** What the live detector is looking at, or the virtual camera's scene. */
export function FocusLabel({ label, tag, pen }: { label: string | null; tag?: string | null; pen: string }) {
  return (
    <View style={styles.slot} pointerEvents="none">
      {label ? (
        <Animated.View key={label} entering={ZoomIn.springify().damping(16).stiffness(260)} exiting={FadeOut.duration(140)}>
          <Glass style={styles.pill}>
            <View style={styles.row}>
              <View style={[styles.pen, { backgroundColor: pen }]} />
              {tag ? <Text style={styles.tag}>{tag}</Text> : null}
              <DecryptedText text={label} style={styles.text} speed={22} scrambles={2} />
            </View>
          </Glass>
        </Animated.View>
      ) : (
        <Animated.View entering={FadeIn} />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  slot: { height: 34, alignItems: 'center', justifyContent: 'center' },
  pill: { height: 30, borderRadius: 15, paddingHorizontal: 12, justifyContent: 'center' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  pen: { width: 6, height: 6, borderRadius: 3 },
  tag: { color: faint, fontFamily: fonts.mono, fontSize: 10, letterSpacing: 1.2 },
  text: { color: paper, fontFamily: fonts.mono, fontSize: 12.5, letterSpacing: 0.3 },
});

import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeOut, ZoomIn } from 'react-native-reanimated';

import { faint, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Glass } from './Glass';

/** What the live detector is looking at, or the virtual camera's scene. */
export function FocusLabel({ label, tag, pen }: { label: string | null; tag?: string | null; pen: string }) {
  return (
    <View style={styles.slot} pointerEvents="none">
      {label ? (
        <Animated.View key={label} entering={ZoomIn.duration(240)} exiting={FadeOut.duration(140)}>
          <Glass style={styles.pill}>
            <View style={styles.row}>
              {tag ? <Text style={styles.tag}>{tag}</Text> : null}
              <Text style={styles.text}>{label}</Text>
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
  tag: { color: faint, ...face.semibold, fontSize: 13 },
  text: { color: paper, ...face.semibold, fontSize: 13 },
});

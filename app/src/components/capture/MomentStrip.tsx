import { Image } from 'expo-image';
import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeInUp } from 'react-native-reanimated';

import type { Moment } from '../../lib/types';
import { PressScale } from '../../motion/PressScale';
import { paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';

const fmt = (ms: number) => `0:${String(Math.floor(ms / 1000)).padStart(2, '0')}`;

/**
 * A video's keyframes, or a capture's photos, on the print. The lit one is
 * what's annotated; tap another to read it (instantly, once it has been).
 */
export function MomentStrip({
  moments,
  active,
  pen,
  photos = false,
  onPick,
  onAdd,
}: {
  moments: Moment[];
  active: string;
  pen: string;
  /** Photos are numbered; video frames show their time. */
  photos?: boolean;
  onPick: (uri: string) => void;
  /** Photos only: add another. */
  onAdd?: () => void;
}) {
  return (
    <View style={styles.row}>
      {moments.map((m, i) => {
        const on = m.uri === active;
        const tag = photos ? String(i + 1) : fmt(m.t);
        return (
          <Animated.View key={m.uri} entering={FadeInUp.delay(photos ? i * 50 : 600 + i * 70).springify().damping(16)}>
            <PressScale
              onPress={() => onPick(m.uri)}
              haptic="selection"
              scaleTo={0.9}
              accessibilityRole="button"
              accessibilityLabel={photos ? `Photo ${i + 1}` : `Moment at ${tag}`}
            >
              <View style={[styles.thumb, on && { borderColor: pen }]}>
                <Image source={{ uri: m.uri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={120} />
                <View style={styles.time}>
                  <Text style={styles.timeText}>{tag}</Text>
                </View>
              </View>
            </PressScale>
          </Animated.View>
        );
      })}
      {onAdd ? (
        <Animated.View entering={FadeInUp.delay(moments.length * 50).springify().damping(16)}>
          <PressScale onPress={onAdd} haptic="selection" scaleTo={0.9} accessibilityRole="button" accessibilityLabel="Add another photo">
            <View style={[styles.thumb, styles.add]}>
              <Icon name="plus" size={18} color={paper} stroke={2.2} />
            </View>
          </PressScale>
        </Animated.View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: 6 },
  thumb: {
    width: 42,
    height: 56,
    borderRadius: 9,
    overflow: 'hidden',
    borderWidth: 2,
    borderColor: 'rgba(244,241,234,0.35)',
    backgroundColor: '#111',
  },
  add: { alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(11,11,12,0.6)' },
  time: { position: 'absolute', left: 0, right: 0, bottom: 0, paddingVertical: 1, backgroundColor: 'rgba(11,11,12,0.6)' },
  timeText: { color: paper, fontFamily: fonts.mono, fontSize: 8.5, textAlign: 'center', letterSpacing: 0.3 },
});

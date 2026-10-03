import { Image } from 'expo-image';
import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeInUp } from 'react-native-reanimated';

import type { Moment } from '../../lib/types';
import { PressScale } from '../../motion/PressScale';
import { paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';

const fmt = (ms: number) => `0:${String(Math.floor(ms / 1000)).padStart(2, '0')}`;

/** Video keyframes on the print. The lit one is what's annotated; tap another to re-read it. */
export function MomentStrip({
  moments,
  active,
  pen,
  onPick,
}: {
  moments: Moment[];
  active: string;
  pen: string;
  onPick: (uri: string) => void;
}) {
  return (
    <View style={styles.row}>
      {moments.map((m, i) => {
        const on = m.uri === active;
        return (
          <Animated.View key={m.uri} entering={FadeInUp.delay(600 + i * 70).springify().damping(16)}>
            <PressScale onPress={() => onPick(m.uri)} haptic="selection" scaleTo={0.9} accessibilityRole="button" accessibilityLabel={`Moment at ${fmt(m.t)}`}>
              <View style={[styles.thumb, on && { borderColor: pen }]}>
                <Image source={{ uri: m.uri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={120} />
                <View style={styles.time}>
                  <Text style={styles.timeText}>{fmt(m.t)}</Text>
                </View>
              </View>
            </PressScale>
          </Animated.View>
        );
      })}
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
  time: { position: 'absolute', left: 0, right: 0, bottom: 0, paddingVertical: 1, backgroundColor: 'rgba(11,11,12,0.6)' },
  timeText: { color: paper, fontFamily: fonts.mono, fontSize: 8.5, textAlign: 'center', letterSpacing: 0.3 },
});

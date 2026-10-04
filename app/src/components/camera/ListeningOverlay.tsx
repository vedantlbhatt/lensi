import { LinearGradient } from 'expo-linear-gradient';
import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeInDown, FadeOut } from 'react-native-reanimated';

import { BlurText } from '../../motion/BlurText';
import { ShinyText } from '../../motion/ShinyText';
import { faint, paper } from '../../theme/tokens';
import { face } from '../../theme/type';

/**
 * While the mic is held: the camera dims from the bottom, and what you say
 * appears large across the view, a word at a time.
 */
export function ListeningOverlay({ transcript, pen, top }: { transcript: string; pen: string; top: number }) {
  const words = transcript.trim();
  return (
    <Animated.View entering={FadeIn.duration(200)} exiting={FadeOut.duration(220)} style={StyleSheet.absoluteFill} pointerEvents="none">
      <LinearGradient colors={['rgba(11,11,12,0.55)', 'rgba(11,11,12,0.1)', 'rgba(11,11,12,0.75)']} locations={[0, 0.45, 1]} style={StyleSheet.absoluteFill} />
      <View style={[styles.text, { top }]}>
        <View style={styles.kickerRow}>
          <Text style={styles.kicker}>Listening. Let go to ask.</Text>
        </View>
        {words ? (
          <Animated.View entering={FadeInDown.duration(240)}>
            <BlurText text={words} style={styles.words} step={0} duration={420} />
          </Animated.View>
        ) : (
          <ShinyText text="Ask about what you see…" style={styles.placeholder} />
        )}
      </View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  text: { position: 'absolute', left: 22, right: 22, gap: 14 },
  kickerRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  kicker: { color: faint, ...face.medium, fontSize: 12 },
  words: { color: paper, ...face.bold, fontSize: 34, lineHeight: 38, letterSpacing: -0.6 },
  placeholder: { color: paper, ...face.semibold, fontSize: 24 },
});

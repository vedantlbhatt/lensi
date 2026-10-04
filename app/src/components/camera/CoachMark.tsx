import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeInDown, FadeOut } from 'react-native-reanimated';

import { RotatingText } from '../../motion/RotatingText';
import { paper } from '../../theme/tokens';
import { face } from '../../theme/type';

const THINGS = ['the coffee machine', 'a breaker box', 'your router', 'a houseplant', 'the dishwasher', 'a car engine'];

/** First run only: what to do, said once, then out of the way. */
export function CoachMark({ pen, top }: { pen: string; top: number }) {
  return (
    <Animated.View
      entering={FadeInDown.delay(500).duration(700)}
      exiting={FadeOut.duration(250)}
      style={[styles.wrap, { top }]}
      pointerEvents="none"
    >
      <Text style={styles.lead}>Point at</Text>
      <View style={styles.rotor}>
        <RotatingText words={THINGS} style={[styles.thing, { color: pen }]} interval={2000} />
      </View>
      <Text style={styles.hint}>Tap for a photo, hold for video, hold the mic to ask.</Text>
    </Animated.View>
  );
}

const shadow = { textShadowColor: 'rgba(0,0,0,0.55)', textShadowRadius: 14, textShadowOffset: { width: 0, height: 2 } };

const styles = StyleSheet.create({
  wrap: { position: 'absolute', left: 24, right: 24, alignItems: 'center' },
  lead: { color: paper, ...face.semibold, fontSize: 22, lineHeight: 27, ...shadow },
  rotor: { height: 44, justifyContent: 'center', overflow: 'hidden' },
  thing: { ...face.bold, fontSize: 34, lineHeight: 40, letterSpacing: -0.6, ...shadow },
  hint: { color: paper, ...face.medium, fontSize: 14, marginTop: 14, textAlign: 'center', ...shadow },
});

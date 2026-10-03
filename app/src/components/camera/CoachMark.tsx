import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeInDown, FadeOut } from 'react-native-reanimated';

import { RotatingText } from '../../motion/RotatingText';
import { faint, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';

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
      <View style={styles.hints}>
        <Text style={styles.hint}>TAP · PHOTO</Text>
        <Text style={styles.dot}>/</Text>
        <Text style={styles.hint}>HOLD · VIDEO</Text>
        <Text style={styles.dot}>/</Text>
        <Text style={styles.hint}>HOLD MIC · ASK</Text>
      </View>
    </Animated.View>
  );
}

const shadow = { textShadowColor: 'rgba(0,0,0,0.55)', textShadowRadius: 14, textShadowOffset: { width: 0, height: 2 } };

const styles = StyleSheet.create({
  wrap: { position: 'absolute', left: 24, right: 24, alignItems: 'center' },
  lead: { color: paper, fontFamily: fonts.serifItalic, fontSize: 30, lineHeight: 32, ...shadow },
  rotor: { height: 44, justifyContent: 'center', overflow: 'hidden' },
  thing: { fontFamily: fonts.display, fontSize: 34, lineHeight: 40, letterSpacing: -1.1, ...shadow },
  hints: { flexDirection: 'row', gap: 8, marginTop: 14, alignItems: 'center' },
  hint: { color: paper, fontFamily: fonts.mono, fontSize: 10.5, letterSpacing: 1.3, ...shadow },
  dot: { color: faint, fontFamily: fonts.mono, fontSize: 10.5 },
});

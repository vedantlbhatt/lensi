import { useEffect } from 'react';
import { StyleSheet, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { interpolate, useAnimatedStyle, useSharedValue, withSpring, type SharedValue } from 'react-native-reanimated';

import { Ripple } from '../../motion/Ripple';
import { springs } from '../../theme/motion';
import { ink, paper } from '../../theme/tokens';
import { Icon } from '../icons/Icon';
import { Glass } from './Glass';

export const MIC = 50;

/**
 * Push-to-talk, the heyclicky way: hold, ask out loud, let go. While held the
 * button swells into the lens colour and breathes with your voice.
 */
export function MicButton({
  pen,
  listening,
  level,
  onHoldStart,
  onHoldEnd,
  onTap,
}: {
  pen: string;
  listening: boolean;
  level: SharedValue<number>;
  onHoldStart: () => void;
  onHoldEnd: () => void;
  onTap: () => void;
}) {
  const press = useSharedValue(0);
  const tap = Gesture.Tap()
    .maxDuration(180)
    .runOnJS(true)
    .onBegin(() => (press.value = withSpring(1, springs.press)))
    .onEnd((_e, ok) => ok && onTap())
    .onFinalize(() => (press.value = withSpring(0, springs.press)));
  const hold = Gesture.LongPress()
    .minDuration(180)
    .maxDistance(160)
    .runOnJS(true)
    .onStart(onHoldStart)
    .onFinalize(() => {
      press.value = withSpring(0, springs.press);
      onHoldEnd();
    });

  const on = useSharedValue(0);
  useEffect(() => {
    on.value = withSpring(listening ? 1 : 0, springs.arrive);
  }, [listening, on]);
  const body = useAnimatedStyle(() => ({
    transform: [{ scale: (1 + on.value * 0.22 + level.value * 0.18 * on.value) * (1 - press.value * 0.08) }],
  }));
  const fill = useAnimatedStyle(() => ({ opacity: on.value }));
  const glow = useAnimatedStyle(() => ({
    opacity: on.value * 0.55,
    transform: [{ scale: 1.1 + level.value * 0.9 }],
  }));

  return (
    <GestureDetector gesture={Gesture.Exclusive(hold, tap)}>
      <Animated.View style={[styles.wrap, body]} accessibilityRole="button" accessibilityLabel="Hold to ask out loud" collapsable={false}>
        <Animated.View style={[styles.glow, { backgroundColor: pen }, glow]} pointerEvents="none" />
        {listening ? (
          <View style={styles.rippleOrigin} pointerEvents="none">
            <Ripple size={MIC} color={pen} repeat duration={1300} grow={2} />
          </View>
        ) : null}
        <Glass style={styles.btn}>
          <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: pen }, fill]} />
          <View style={styles.center}>
            <Icon name="mic" size={23} color={listening ? ink : paper} fill={listening ? ink : undefined} />
          </View>
        </Glass>
      </Animated.View>
    </GestureDetector>
  );
}

const styles = StyleSheet.create({
  wrap: { width: MIC, height: MIC, alignItems: 'center', justifyContent: 'center' },
  btn: { width: MIC, height: MIC, borderRadius: MIC / 2 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  glow: { position: 'absolute', width: MIC, height: MIC, borderRadius: MIC / 2 },
  rippleOrigin: { position: 'absolute', left: MIC / 2, top: MIC / 2 },
});

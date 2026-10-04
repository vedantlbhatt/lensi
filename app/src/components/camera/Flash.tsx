import { forwardRef, useImperativeHandle } from 'react';
import { StyleSheet } from 'react-native';
import Animated, { Easing, useAnimatedStyle, useSharedValue, withSequence, withTiming } from 'react-native-reanimated';

export type FlashRef = { fire(): void };

/** The shutter blink: a quick white veil that hides the hand-off to the still. */
export const Flash = forwardRef<FlashRef>(function Flash(_, ref) {
  const o = useSharedValue(0);
  useImperativeHandle(ref, () => ({
    fire: () => {
      o.value = withSequence(withTiming(0.9, { duration: 70, easing: Easing.out(Easing.quad) }), withTiming(0, { duration: 420, easing: Easing.bezier(0.16, 1, 0.3, 1) }));
    },
  }));
  const a = useAnimatedStyle(() => ({ opacity: o.value }));
  return <Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill, styles.veil, a]} />;
});

const styles = StyleSheet.create({ veil: { backgroundColor: '#FFFDF6' } });

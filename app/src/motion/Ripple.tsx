import { useEffect } from 'react';
import { StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import Animated, { Easing, useAnimatedStyle, useSharedValue, withDelay, withRepeat, withTiming } from 'react-native-reanimated';

/** An expanding ring. `repeat` keeps it breathing (listening, waiting). */
export function Ripple({
  size,
  color,
  delay = 0,
  duration = 900,
  repeat = false,
  grow = 2.4,
  stroke = 2,
  style,
}: {
  size: number;
  color: string;
  delay?: number;
  duration?: number;
  repeat?: boolean;
  grow?: number;
  stroke?: number;
  style?: StyleProp<ViewStyle>;
}) {
  const t = useSharedValue(0);
  useEffect(() => {
    const anim = withTiming(1, { duration, easing: Easing.out(Easing.cubic) });
    t.value = withDelay(delay, repeat ? withRepeat(anim, -1, false) : anim);
  }, [delay, duration, repeat, t]);
  const a = useAnimatedStyle(() => ({
    opacity: (1 - t.value) * 0.9,
    transform: [{ scale: 1 + t.value * (grow - 1) }],
  }));
  return (
    <Animated.View
      pointerEvents="none"
      style={[
        styles.ring,
        { width: size, height: size, borderRadius: size / 2, marginLeft: -size / 2, marginTop: -size / 2, borderColor: color, borderWidth: stroke },
        style,
        a,
      ]}
    />
  );
}

const styles = StyleSheet.create({ ring: { position: 'absolute', left: 0, top: 0 } });

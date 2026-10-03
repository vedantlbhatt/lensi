import * as Haptics from 'expo-haptics';
import type { ReactNode } from 'react';
import { Pressable, type GestureResponderEvent, type PressableProps, type StyleProp, type ViewStyle } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withSpring } from 'react-native-reanimated';

import { getSettings } from '../lib/settings';
import { springs } from '../theme/motion';

/**
 * Every tappable thing squishes under the thumb and settles with one small
 * overshoot. `haptic` fires on press-in, where a real button clicks.
 */
export function PressScale({
  children,
  style,
  scaleTo = 0.9,
  haptic = 'light',
  onPressIn,
  onPressOut,
  ...rest
}: Omit<PressableProps, 'style' | 'children'> & {
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  scaleTo?: number;
  haptic?: 'light' | 'medium' | 'selection' | null;
}) {
  const s = useSharedValue(1);
  const a = useAnimatedStyle(() => ({ transform: [{ scale: s.value }] }));
  return (
    <Pressable
      {...rest}
      onPressIn={(e: GestureResponderEvent) => {
        s.value = withSpring(scaleTo, springs.press);
        if (haptic && getSettings().haptics) {
          if (haptic === 'selection') Haptics.selectionAsync().catch(() => {});
          else Haptics.impactAsync(haptic === 'medium' ? Haptics.ImpactFeedbackStyle.Medium : Haptics.ImpactFeedbackStyle.Light).catch(() => {});
        }
        onPressIn?.(e);
      }}
      onPressOut={(e: GestureResponderEvent) => {
        s.value = withSpring(1, { ...springs.press, damping: 9 });
        onPressOut?.(e);
      }}
    >
      <Animated.View style={[style, a]}>{children}</Animated.View>
    </Pressable>
  );
}

import { useEffect } from 'react';
import { Image, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withRepeat, withTiming, Easing } from 'react-native-reanimated';

const TILE = require('../../assets/grain.png');

/**
 * Film grain (after React Bits' Noise): a tiled noise texture that jitters a
 * few pixels at ~10 fps. Puts a little tooth on flat glass and dark sheets so
 * they read as material instead of a gradient.
 */
export function Grain({ opacity = 0.06, style, animated = true }: { opacity?: number; style?: StyleProp<ViewStyle>; animated?: boolean }) {
  const t = useSharedValue(0);
  useEffect(() => {
    if (animated) t.value = withRepeat(withTiming(1, { duration: 1000, easing: Easing.steps ? Easing.steps(10) : Easing.linear }), -1, false);
  }, [animated, t]);
  const a = useAnimatedStyle(() => {
    const k = Math.floor(t.value * 10);
    return { transform: [{ translateX: ((k * 37) % 23) - 11 }, { translateY: ((k * 53) % 19) - 9 }] };
  });
  return (
    <View pointerEvents="none" style={[StyleSheet.absoluteFill, { overflow: 'hidden', opacity }, style]}>
      <Animated.View style={[styles.layer, a]}>
        <Image source={TILE} resizeMode="repeat" style={StyleSheet.absoluteFill} />
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({ layer: { position: 'absolute', left: -24, top: -24, right: -24, bottom: -24 } });

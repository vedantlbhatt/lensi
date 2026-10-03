import { useEffect } from 'react';
import { StyleSheet, View, type StyleProp, type TextStyle } from 'react-native';
import Animated, {
  Easing,
  interpolate,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';

/**
 * A band of light sweeps across the letters while `active` (after React Bits'
 * ShinyText). Each glyph brightens as the band passes it, so it works without
 * masks or gradients and reads the same on every platform.
 */
export function ShinyText({
  text,
  style,
  active = true,
  period = 1600,
  dim = 0.45,
}: {
  text: string;
  style?: StyleProp<TextStyle>;
  active?: boolean;
  period?: number;
  dim?: number;
}) {
  const phase = useSharedValue(0);
  useEffect(() => {
    if (active) {
      phase.value = 0;
      phase.value = withRepeat(withTiming(1, { duration: period, easing: Easing.inOut(Easing.quad) }), -1, false);
    } else {
      phase.value = withTiming(2, { duration: 300 });
    }
  }, [active, period, phase]);
  const chars = Array.from(text);
  return (
    <View style={styles.row} accessible accessibilityLabel={text}>
      {chars.map((c, i) => (
        <Glyph key={i} c={c} i={i} n={chars.length} phase={phase} style={style} dim={dim} />
      ))}
    </View>
  );
}

function Glyph({
  c,
  i,
  n,
  phase,
  style,
  dim,
}: {
  c: string;
  i: number;
  n: number;
  phase: SharedValue<number>;
  style?: StyleProp<TextStyle>;
  dim: number;
}) {
  const a = useAnimatedStyle(() => {
    if (phase.value > 1.5) return { opacity: 1 };
    // Band travels from before the first glyph to past the last.
    const center = interpolate(phase.value, [0, 1], [-0.25, 1.25]);
    const pos = n <= 1 ? 0.5 : i / (n - 1);
    const d = Math.abs(pos - center);
    return { opacity: interpolate(d, [0, 0.18], [1, dim], 'clamp') };
  });
  return (
    <Animated.Text style={[style, a]} importantForAccessibility="no">
      {c}
    </Animated.Text>
  );
}

const styles = StyleSheet.create({ row: { flexDirection: 'row' } });

import { useEffect } from 'react';
import { StyleSheet, Text, View, type StyleProp, type TextStyle } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withSpring } from 'react-native-reanimated';

const DIGITS = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

/**
 * Odometer digits (after React Bits' Counter): each place is a column of 0-9
 * that springs to its value, so 03 → 04 rolls rather than swaps.
 */
export function RollingNumber({
  value,
  pad = 2,
  style,
  lineHeight,
}: {
  value: number;
  pad?: number;
  style?: StyleProp<TextStyle>;
  lineHeight: number;
}) {
  const s = String(Math.max(0, Math.floor(value))).padStart(pad, '0');
  return (
    <View style={styles.row} accessible accessibilityLabel={String(value)}>
      {Array.from(s).map((d, i) => (
        <Place key={s.length - i} digit={Number(d)} style={style} lineHeight={lineHeight} />
      ))}
    </View>
  );
}

function Place({ digit, style, lineHeight }: { digit: number; style?: StyleProp<TextStyle>; lineHeight: number }) {
  const y = useSharedValue(digit);
  useEffect(() => {
    y.value = withSpring(digit, { damping: 16, stiffness: 180, mass: 0.8 });
  }, [digit, y]);
  const a = useAnimatedStyle(() => ({ transform: [{ translateY: -y.value * lineHeight }] }));
  return (
    <View style={{ height: lineHeight, overflow: 'hidden' }}>
      <Animated.View style={a}>
        {DIGITS.map((d) => (
          <Text key={d} style={[style, { height: lineHeight, lineHeight }]}>
            {d}
          </Text>
        ))}
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({ row: { flexDirection: 'row' } });

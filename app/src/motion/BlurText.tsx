import { useEffect } from 'react';
import { StyleSheet, Text, View, type StyleProp, type TextStyle } from 'react-native';
import Animated, {
  Easing,
  interpolate,
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';

import { rgba } from '../lib/color';

/**
 * Words resolve out of a blur, one after another (after React Bits' BlurText).
 * Native text can't take a blur filter, so each word starts as nothing but its
 * own soft shadow in the text colour, then the shadow tightens to zero while
 * the glyphs fade in: a real blur-to-sharp, on iOS and on the web.
 */
export function BlurText({
  text,
  style,
  delay = 0,
  step = 70,
  duration = 620,
  color = '#F4F1EA',
  rise = 10,
}: {
  text: string;
  style?: StyleProp<TextStyle>;
  delay?: number;
  step?: number;
  duration?: number;
  color?: string;
  rise?: number;
}) {
  const words = text.split(/\s+/).filter(Boolean);
  return (
    <View style={styles.row} accessible accessibilityLabel={text}>
      {words.map((w, i) => (
        <Word key={`${i}-${w}`} word={w} last={i === words.length - 1} style={style} color={color} delay={delay + i * step} duration={duration} rise={rise} />
      ))}
    </View>
  );
}

function Word({
  word,
  last,
  style,
  color,
  delay,
  duration,
  rise,
}: {
  word: string;
  last: boolean;
  style?: StyleProp<TextStyle>;
  color: string;
  delay: number;
  duration: number;
  rise: number;
}) {
  const t = useSharedValue(0);
  useEffect(() => {
    t.value = 0;
    t.value = withDelay(delay, withTiming(1, { duration, easing: Easing.bezier(0.16, 1, 0.3, 1) }));
  }, [word, delay, duration, t]);
  const a = useWordStyle(t, color, rise);
  return (
    <Animated.Text style={[style, a]} importantForAccessibility="no" accessibilityElementsHidden>
      {word}
      {last ? '' : ' '}
    </Animated.Text>
  );
}

function useWordStyle(t: SharedValue<number>, color: string, rise: number) {
  return useAnimatedStyle(() => {
    const v = t.value;
    // Glyph alpha comes in late; the halo carries the first half.
    const glyph = interpolate(v, [0.25, 0.85], [0, 1], 'clamp');
    return {
      // rgba() rounds the alpha: as a word settles it falls below 1e-6, and an exponent
      // ("9.4e-7") isn't a colour Reanimated can parse; it throws, which aborts a Release build.
      color: rgba(color, glyph),
      textShadowColor: rgba(color, interpolate(v, [0, 0.4, 1], [0, 0.9, 0], 'clamp')),
      textShadowRadius: interpolate(v, [0, 1], [14, 0]),
      textShadowOffset: { width: 0, height: 0 },
      opacity: interpolate(v, [0, 0.15], [0, 1], 'clamp'),
      transform: [{ translateY: interpolate(v, [0, 1], [rise, 0]) }],
    };
  });
}



/** Static fallback with the same layout, for places that must not animate. */
export function PlainText({ text, style }: { text: string; style?: StyleProp<TextStyle> }) {
  return <Text style={style}>{text}</Text>;
}

const styles = StyleSheet.create({ row: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'baseline' } });

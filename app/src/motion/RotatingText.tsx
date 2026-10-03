import { useEffect, useState } from 'react';
import { type StyleProp, type TextStyle } from 'react-native';
import Animated, { Easing, FadeInDown, FadeOutUp } from 'react-native-reanimated';

/** Cycles through words with a short vertical hand-off (after React Bits' RotatingText). */
export function RotatingText({
  words,
  style,
  interval = 2200,
}: {
  words: string[];
  style?: StyleProp<TextStyle>;
  interval?: number;
}) {
  const [i, setI] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setI((x) => (x + 1) % words.length), interval);
    return () => clearInterval(t);
  }, [words.length, interval]);
  return (
    <Animated.Text
      key={i}
      entering={FadeInDown.duration(420).easing(Easing.bezier(0.16, 1, 0.3, 1)).withInitialValues({ transform: [{ translateY: 14 }] })}
      exiting={FadeOutUp.duration(260)}
      style={style}
    >
      {words[i]}
    </Animated.Text>
  );
}

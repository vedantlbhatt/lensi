import { useEffect, useRef, useState } from 'react';
import { Text, type StyleProp, type TextStyle } from 'react-native';

const GLYPHS = '#%&*+=<>/\\|01_~^:;';

/**
 * Characters arrive scrambled and lock in left to right (after React Bits'
 * DecryptedText). Used for labels the model reads off the world: it should
 * feel like the machine is reading, briefly, and then get out of the way.
 */
export function DecryptedText({
  text,
  style,
  delay = 0,
  speed = 28,
  scrambles = 3,
  numberOfLines,
}: {
  text: string;
  style?: StyleProp<TextStyle>;
  numberOfLines?: number;
  delay?: number;
  /** Milliseconds per tick. */
  speed?: number;
  /** Ticks each character spends scrambling before it settles. */
  scrambles?: number;
}) {
  const [shown, setShown] = useState(() => text.replace(/\S/g, ' '));
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    let tick = 0;
    const total = text.length + scrambles;
    const start = setTimeout(() => {
      timer.current = setInterval(() => {
        tick += 1;
        let out = '';
        for (let i = 0; i < text.length; i++) {
          const c = text[i];
          if (c === ' ' || i < tick - scrambles) out += c;
          else if (i < tick) out += GLYPHS[(i * 7 + tick * 3) % GLYPHS.length];
          else out += ' ';
        }
        setShown(out);
        if (tick >= total && timer.current) {
          clearInterval(timer.current);
          timer.current = null;
          setShown(text);
        }
      }, speed);
    }, delay);
    return () => {
      clearTimeout(start);
      if (timer.current) clearInterval(timer.current);
    };
  }, [text, delay, speed, scrambles]);

  return (
    <Text style={style} accessibilityLabel={text} numberOfLines={numberOfLines} ellipsizeMode="clip">
      {shown}
    </Text>
  );
}

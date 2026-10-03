import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeOutUp, SlideInUp } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { glassStrong, hairline, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';

type T = { id: number; text: string };
let push: ((t: T) => void) | null = null;

/** Fire-and-forget status line at the top of the screen. */
export function toast(text: string) {
  push?.({ id: Date.now(), text });
}

export function ToastHost() {
  const insets = useSafeAreaInsets();
  const [t, setT] = useState<T | null>(null);
  useEffect(() => {
    push = setT;
    return () => {
      push = null;
    };
  }, []);
  useEffect(() => {
    if (!t) return;
    const h = setTimeout(() => setT((cur) => (cur?.id === t.id ? null : cur)), 2400);
    return () => clearTimeout(h);
  }, [t]);
  return (
    <View pointerEvents="none" style={[styles.host, { top: insets.top + 54 }]}>
      {t ? (
        <Animated.View key={t.id} entering={SlideInUp.springify().damping(18)} exiting={FadeOutUp.duration(200)} style={styles.pill}>
          <Text style={styles.text}>{t.text}</Text>
        </Animated.View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  host: { position: 'absolute', left: 0, right: 0, alignItems: 'center', zIndex: 100 },
  pill: {
    maxWidth: '86%',
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: 14,
    backgroundColor: glassStrong,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
  },
  text: { color: paper, fontFamily: fonts.mono, fontSize: 12.5, letterSpacing: 0.2, textAlign: 'center' },
});

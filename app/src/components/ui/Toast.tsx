import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeOutUp, SlideInUp } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { glassStrong, hairline, ink, paper } from '../../theme/tokens';
import { haptic } from '../../lib/haptics';
import { fonts } from '../../theme/type';

type Action = { label: string; run: () => void };
type T = { id: number; text: string; action?: Action };
let push: ((t: T) => void) | null = null;

/** Status line at the top of the screen; with an action (Undo) it stays a little longer and takes a tap. */
export function toast(text: string, action?: Action) {
  push?.({ id: Date.now(), text, action });
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
    const h = setTimeout(() => setT((cur) => (cur?.id === t.id ? null : cur)), t.action ? 3600 : 2400);
    return () => clearTimeout(h);
  }, [t]);
  return (
    <View pointerEvents="box-none" style={[styles.host, { top: insets.top + 54 }]}>
      {t ? (
        <Animated.View
          key={t.id}
          entering={SlideInUp.springify().damping(18)}
          exiting={FadeOutUp.duration(200)}
          style={[styles.pill, t.action && styles.pillAction]}
          pointerEvents={t.action ? 'auto' : 'none'}
        >
          <Text style={styles.text}>{t.text}</Text>
          {t.action ? (
            <Pressable
              hitSlop={10}
              accessibilityRole="button"
              accessibilityLabel={t.action.label}
              onPress={() => {
                haptic.tap();
                t.action?.run();
                setT(null);
              }}
            >
              <View style={styles.actionPill}>
                <Text style={styles.action}>{t.action.label}</Text>
              </View>
            </Pressable>
          ) : null}
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
  pillAction: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 6, paddingRight: 6 },
  text: { color: paper, fontFamily: fonts.mono, fontSize: 12.5, letterSpacing: 0.2, textAlign: 'center' },
  actionPill: { height: 26, paddingHorizontal: 11, borderRadius: 13, backgroundColor: paper, justifyContent: 'center' },
  action: { color: ink, fontFamily: fonts.textBold, fontSize: 13 },
});

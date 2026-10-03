import * as Haptics from 'expo-haptics';
import { useEffect } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { interpolateColor, useAnimatedStyle, useSharedValue, withSpring } from 'react-native-reanimated';

import type { Lens } from '../lib/annotate';

export const LENSES: { key: Lens; name: string; color: string }[] = [
  { key: 'identify', name: 'Identify', color: '#2E9BFF' },
  { key: 'fix', name: 'Fix', color: '#FF5A4E' },
  { key: 'shop', name: 'Shop', color: '#14B88A' },
  { key: 'safe', name: 'Safe', color: '#FF7FB6' },
  { key: 'learn', name: 'Learn', color: '#8B6CFF' },
];

export function lensColor(lens: Lens) {
  return LENSES.find((l) => l.key === lens)?.color ?? '#2E9BFF';
}

function LensPill({ name, color, active, onPress }: { name: string; color: string; active: boolean; onPress: () => void }) {
  const on = useSharedValue(active ? 1 : 0);
  useEffect(() => {
    on.value = withSpring(active ? 1 : 0, { damping: 18, stiffness: 260 });
  }, [active, on]);
  const style = useAnimatedStyle(() => ({
    backgroundColor: interpolateColor(on.value, [0, 1], ['rgba(0,0,0,0)', color]),
    transform: [{ scale: 0.94 + on.value * 0.06 }],
  }));
  return (
    <Pressable onPress={onPress} hitSlop={6}>
      <Animated.View style={[styles.pill, style]}>
        <Text style={styles.text}>{name}</Text>
      </Animated.View>
    </Pressable>
  );
}

export function LensBar({ lens, onChange }: { lens: Lens; onChange: (l: Lens) => void }) {
  return (
    <View style={styles.bar}>
      {LENSES.map((l) => (
        <LensPill
          key={l.key}
          name={l.name}
          color={l.color}
          active={l.key === lens}
          onPress={() => {
            if (l.key !== lens) Haptics.selectionAsync();
            onChange(l.key);
          }}
        />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    alignSelf: 'center',
    gap: 2,
    padding: 4,
    borderRadius: 22,
    backgroundColor: 'rgba(12,12,14,0.6)',
  },
  pill: { paddingHorizontal: 13, height: 34, borderRadius: 17, justifyContent: 'center' },
  text: { color: '#fff', fontSize: 15, fontWeight: '600' },
});

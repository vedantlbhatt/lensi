import { Image } from 'expo-image';
import { useEffect } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withSequence, withSpring, withTiming } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { springs } from '../../theme/motion';
import { paper } from '../../theme/tokens';
import { Icon } from '../icons/Icon';
import { Glass } from './Glass';

export const MEMORIES_SIZE = 50;

/**
 * Latest capture as a little stacked print. When a new one lands it drops in
 * with a tilt, so you see your capture being filed.
 */
export function MemoriesButton({ uri, count, onPress }: { uri: string | null; count: number; onPress: () => void }) {
  const drop = useSharedValue(1);
  useEffect(() => {
    if (!uri) return;
    drop.value = 0;
    drop.value = withSequence(withTiming(0, { duration: 1 }), withSpring(1, springs.pop));
  }, [uri, drop]);
  const a = useAnimatedStyle(() => ({
    opacity: Math.min(1, drop.value * 1.6),
    transform: [{ scale: 0.55 + drop.value * 0.45 }, { rotate: `${(1 - drop.value) * -14}deg` }],
  }));
  return (
    <PressScale onPress={onPress} accessibilityRole="button" accessibilityLabel={`Memories, ${count} saved`} hitSlop={8} scaleTo={0.88}>
      <View style={styles.wrap}>
        {count > 1 ? <View style={[styles.card, styles.back]} /> : null}
        {uri ? (
          <Animated.View style={[styles.card, a]}>
            <Image source={{ uri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={0} />
          </Animated.View>
        ) : (
          <Glass style={styles.card}>
            <View style={styles.center}>
              <Icon name="stack" size={22} />
            </View>
          </Glass>
        )}
      </View>
    </PressScale>
  );
}

const styles = StyleSheet.create({
  wrap: { width: MEMORIES_SIZE, height: MEMORIES_SIZE },
  card: {
    position: 'absolute',
    inset: 0,
    borderRadius: 14,
    borderWidth: 2,
    borderColor: paper,
    overflow: 'hidden',
    borderCurve: 'continuous',
  },
  back: { transform: [{ rotate: '8deg' }, { translateX: 3 }], opacity: 0.5, backgroundColor: 'rgba(255,255,255,0.25)' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
});

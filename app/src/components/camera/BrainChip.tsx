import { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withRepeat, withSequence, withTiming, Easing } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import type { EngineId } from '../../lib/types';
import { faint, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';
import { Glass } from './Glass';

const COPY: Record<EngineId | 'checking', string> = {
  apple: 'On-device',
  cloud: 'Claude',
  vision: 'Eyes only',
  checking: 'Waking',
};

/** Which brain will answer. The dot breathes so it reads as alive. */
export function BrainChip({ engine, pen, onPress }: { engine: EngineId | null; pen: string; onPress: () => void }) {
  const pulse = useSharedValue(0);
  useEffect(() => {
    pulse.value = withRepeat(withSequence(withTiming(1, { duration: 1100, easing: Easing.inOut(Easing.sin) }), withTiming(0, { duration: 1100, easing: Easing.inOut(Easing.sin) })), -1);
  }, [pulse]);
  const dot = useAnimatedStyle(() => ({ opacity: 0.55 + pulse.value * 0.45, transform: [{ scale: 0.85 + pulse.value * 0.25 }] }));
  const color = engine === 'apple' ? pen : engine === 'cloud' ? paper : faint;
  return (
    <PressScale onPress={onPress} accessibilityRole="button" accessibilityLabel={`Brain: ${COPY[engine ?? 'checking']}. Open settings.`} scaleTo={0.92}>
      <Glass style={styles.chip}>
        <View style={styles.row}>
          {engine === 'apple' ? (
            <Icon name="spark" size={14} color={pen} fill={pen} stroke={1.2} />
          ) : (
            <Animated.View style={[styles.dot, { backgroundColor: color }, dot]} />
          )}
          <Text style={styles.text}>{COPY[engine ?? 'checking'].toUpperCase()}</Text>
        </View>
      </Glass>
    </PressScale>
  );
}

const styles = StyleSheet.create({
  chip: { height: 32, borderRadius: 16, paddingHorizontal: 12, justifyContent: 'center' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  dot: { width: 7, height: 7, borderRadius: 4 },
  text: { color: paper, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.1 },
});

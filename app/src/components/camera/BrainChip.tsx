import { StyleSheet, Text, View } from 'react-native';

import { PressScale } from '../../motion/PressScale';
import { cloudProvider } from '../../lib/engines/cloud';
import type { EngineId } from '../../lib/types';
import { paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Icon } from '../icons/Icon';
import { Glass } from './Glass';

const COPY: Record<EngineId | 'checking', string> = {
  apple: 'On-device',
  cloud: 'Claude',
  vision: 'Eyes only',
  checking: 'Waking',
};

/** Which brain will answer. Tap for settings. */
export function BrainChip({ engine, pen, onPress }: { engine: EngineId | null; pen: string; onPress: () => void }) {
  // A server in mock mode answers from a script: don't call that Claude.
  const name = engine === 'cloud' && cloudProvider() === 'mock' ? 'Mock server' : COPY[engine ?? 'checking'];
  return (
    <PressScale onPress={onPress} accessibilityRole="button" accessibilityLabel={`Brain: ${name}. Open settings.`} scaleTo={0.92}>
      <Glass style={styles.chip}>
        <View style={styles.row}>
          {engine === 'apple' ? <Icon name="spark" size={14} color={pen} fill={pen} stroke={1.2} /> : null}
          <Text style={styles.text}>{name}</Text>
        </View>
      </Glass>
    </PressScale>
  );
}

const styles = StyleSheet.create({
  chip: { height: 32, borderRadius: 16, paddingHorizontal: 12, justifyContent: 'center' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  text: { color: paper, ...face.medium, fontSize: 12 },
});

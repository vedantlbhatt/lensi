import { StyleSheet, View } from 'react-native';
import Animated, { FadeInRight } from 'react-native-reanimated';

import { ink, paper } from '../../theme/tokens';
import { Icon } from '../icons/Icon';
import { RoundButton } from './RoundButton';

/** Snapchat-style vertical rail, top right. */
export function ToolRail({
  torch,
  live,
  pen,
  onTorch,
  onLive,
  onDrop,
  onSettings,
}: {
  torch: boolean;
  live: boolean;
  pen: string;
  onTorch: () => void;
  onLive: () => void;
  onDrop: () => void;
  onSettings: () => void;
}) {
  const items = [
    { key: 'torch', node: <RoundButton label={torch ? 'Torch off' : 'Torch on'} onPress={onTorch} active={torch} activeColor={paper}><Icon name={torch ? 'flash' : 'flashOff'} size={21} color={torch ? ink : paper} fill={torch ? ink : undefined} /></RoundButton> },
    { key: 'live', node: <RoundButton label={live ? 'Leave live pins' : 'Live pins: tap things to pin them in space'} onPress={onLive} active={live} activeColor={pen}><Icon name="live" size={21} color={live ? ink : paper} /></RoundButton> },
    { key: 'drop', node: <RoundButton label="Drop in a photo, video or file" onPress={onDrop}><Icon name="drop" size={21} /></RoundButton> },
    { key: 'settings', node: <RoundButton label="Settings" onPress={onSettings}><Icon name="sliders" size={21} /></RoundButton> },
  ];
  return (
    <View style={styles.rail}>
      {items.map((it, i) => (
        <Animated.View key={it.key} entering={FadeInRight.delay(80 + i * 60).springify().damping(18)}>
          {it.node}
        </Animated.View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({ rail: { gap: 12, alignItems: 'center' } });

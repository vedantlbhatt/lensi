import { BlurView } from 'expo-blur';
import type { ReactNode } from 'react';
import { Platform, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';

import { glass, hairline } from '../../theme/tokens';

/**
 * Smoked glass for camera chrome: a real blur on iOS, a dark tint elsewhere,
 * plus a hairline so it holds its edge against bright scenes.
 */
export function Glass({ children, style, intensity = 28 }: { children?: ReactNode; style?: StyleProp<ViewStyle>; intensity?: number }) {
  return (
    <View style={[styles.base, style]}>
      {Platform.OS === 'ios' ? (
        <BlurView intensity={intensity} tint="dark" style={StyleSheet.absoluteFill} />
      ) : (
        <View style={[StyleSheet.absoluteFill, { backgroundColor: glass }]} />
      )}
      <View style={[StyleSheet.absoluteFill, styles.tint]} />
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  base: { overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth, borderColor: hairline },
  tint: { backgroundColor: 'rgba(11,11,12,0.22)' },
});

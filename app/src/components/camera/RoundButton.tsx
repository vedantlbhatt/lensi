import type { ReactNode } from 'react';
import { StyleSheet } from 'react-native';

import { PressScale } from '../../motion/PressScale';
import { Glass } from './Glass';

export function RoundButton({
  size = 42,
  onPress,
  onLongPress,
  label,
  children,
  active,
  activeColor,
}: {
  size?: number;
  onPress?: () => void;
  onLongPress?: () => void;
  label: string;
  children: ReactNode;
  active?: boolean;
  activeColor?: string;
}) {
  return (
    <PressScale onPress={onPress} onLongPress={onLongPress} accessibilityRole="button" accessibilityLabel={label} hitSlop={6} scaleTo={0.86}>
      <Glass style={[styles.b, { width: size, height: size, borderRadius: size / 2 }, active && activeColor ? { backgroundColor: activeColor } : null]}>
        {children}
      </Glass>
    </PressScale>
  );
}

const styles = StyleSheet.create({ b: { alignItems: 'center', justifyContent: 'center' } });

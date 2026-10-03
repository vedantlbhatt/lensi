import { Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeOut, ZoomIn } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { glassStrong, hairline, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon, type IconName } from '../icons/Icon';

export const MENU = { w: 196, h: 42, wide: 286 };

/**
 * What a long-pressed label can do: be called something else, or go away;
 * when the eyes read text or a code there, copy it (or open its link).
 * Pops out of the label it belongs to; a tap anywhere else folds it.
 */
export function LabelMenu({
  x,
  y,
  below,
  extra,
  onRename,
  onRemove,
  onClose,
}: {
  x: number;
  y: number;
  /** Sits under the label (it was too close to the top), so grow downwards. */
  below: boolean;
  /** Copy what was read there, or open the link a code carries. */
  extra?: { kind: 'copy' | 'open'; run: () => void } | null;
  onRename: () => void;
  onRemove: () => void;
  onClose: () => void;
}) {
  return (
    <View style={StyleSheet.absoluteFill}>
      <Pressable style={StyleSheet.absoluteFill} onPress={onClose} accessibilityLabel="Close label menu" />
      <Animated.View
        entering={ZoomIn.springify().damping(15).stiffness(340)}
        exiting={FadeOut.duration(120)}
        style={[styles.menu, { left: x, top: y, width: extra ? MENU.wide : MENU.w, transformOrigin: below ? 'center top' : 'center bottom' }]}
      >
        {extra ? <Item icon={extra.kind === 'open' ? 'share' : 'paste'} label={extra.kind === 'open' ? 'OPEN' : 'COPY'} onPress={extra.run} /> : null}
        <Item icon="pencil" label="RENAME" onPress={onRename} />
        <Item icon="close" label="REMOVE" onPress={onRemove} tint="#FF9C8F" />
      </Animated.View>
    </View>
  );
}

function Item({ icon, label, onPress, tint = paper }: { icon: IconName; label: string; onPress: () => void; tint?: string }) {
  return (
    <PressScale
      onPress={onPress}
      scaleTo={0.9}
      haptic="selection"
      accessibilityRole="button"
      accessibilityLabel={label.toLowerCase()}
      containerStyle={styles.itemWrap}
      style={styles.itemWrap}
    >
      <View style={styles.item}>
        <Icon name={icon} size={14} color={tint} stroke={2.1} />
        <Text style={[styles.text, { color: tint }]}>{label}</Text>
      </View>
    </PressScale>
  );
}

const styles = StyleSheet.create({
  menu: {
    position: 'absolute',
    height: MENU.h,
    flexDirection: 'row',
    padding: 4,
    gap: 4,
    borderRadius: 14,
    borderCurve: 'continuous',
    backgroundColor: glassStrong,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    shadowColor: '#000',
    shadowOpacity: 0.35,
    shadowRadius: 14,
    shadowOffset: { width: 0, height: 6 },
  },
  itemWrap: { flex: 1 },
  item: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    borderRadius: 10,
    backgroundColor: 'rgba(244,241,234,0.07)',
  },
  text: { fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.2 },
});

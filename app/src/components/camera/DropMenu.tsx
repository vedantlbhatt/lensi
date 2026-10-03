import { Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeOut, ZoomIn, ZoomOut } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { faint, glassStrong, hairline, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon, type IconName } from '../icons/Icon';

export type DropChoice = 'library' | 'files' | 'paste';

const CHOICES: { key: DropChoice; icon: IconName; title: string; hint: string }[] = [
  { key: 'library', icon: 'photo', title: 'Photos & videos', hint: 'FROM YOUR LIBRARY' },
  { key: 'files', icon: 'file', title: 'Files', hint: 'IMAGES, CLIPS' },
  { key: 'paste', icon: 'paste', title: 'Paste', hint: 'WHATEVER YOU COPIED' },
];

/** "Drop anything": a small card that unfolds from the rail. */
export function DropMenu({ top, onPick, onClose }: { top: number; onPick: (c: DropChoice) => void; onClose: () => void }) {
  return (
    <View style={StyleSheet.absoluteFill}>
      <Animated.View entering={FadeIn.duration(160)} exiting={FadeOut.duration(160)} style={[StyleSheet.absoluteFill, styles.scrim]}>
        <Pressable style={StyleSheet.absoluteFill} onPress={onClose} accessibilityLabel="Close" />
      </Animated.View>
      <Animated.View
        entering={ZoomIn.springify().damping(17).stiffness(240).withInitialValues({ transform: [{ scale: 0.6 }] })}
        exiting={ZoomOut.duration(160)}
        style={[styles.card, { top }]}
      >
        <Text style={styles.head}>Drop anything</Text>
        {CHOICES.map((c) => (
          <PressScale key={c.key} onPress={() => onPick(c.key)} scaleTo={0.96} haptic="selection" accessibilityRole="button" accessibilityLabel={c.title}>
            <View style={styles.row}>
              <View style={styles.icon}>
                <Icon name={c.icon} size={20} />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.title}>{c.title}</Text>
                <Text style={styles.hint}>{c.hint}</Text>
              </View>
            </View>
          </PressScale>
        ))}
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  scrim: { backgroundColor: 'rgba(0,0,0,0.28)' },
  card: {
    position: 'absolute',
    right: 64,
    width: 236,
    padding: 10,
    borderRadius: 22,
    borderCurve: 'continuous',
    backgroundColor: glassStrong,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    transformOrigin: 'top right',
  },
  head: { color: paper, fontFamily: 'InstrumentSerif-Italic', fontSize: 22, paddingHorizontal: 8, paddingTop: 4, paddingBottom: 6 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 12, padding: 8, borderRadius: 14 },
  icon: { width: 38, height: 38, borderRadius: 12, backgroundColor: 'rgba(244,241,234,0.08)', alignItems: 'center', justifyContent: 'center' },
  title: { color: paper, fontFamily: fonts.textSemi, fontSize: 15.5 },
  hint: { color: faint, fontFamily: fonts.mono, fontSize: 10, letterSpacing: 1, marginTop: 2 },
});

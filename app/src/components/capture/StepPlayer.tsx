import { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, useAnimatedStyle, useSharedValue, withSpring } from 'react-native-reanimated';

import type { Step } from '../../lib/types';
import { BlurText } from '../../motion/BlurText';
import { PressScale } from '../../motion/PressScale';
import { RollingNumber } from '../../motion/RollingNumber';
import { ShinyText } from '../../motion/ShinyText';
import { springs } from '../../theme/motion';
import { faint, ink, mist, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';

/**
 * One step at a time: an odometer step counter, the instruction resolving out
 * of blur, a segmented progress bar, and big thumb targets.
 */
export function StepPlayer({
  steps,
  index,
  pending,
  pen,
  narrate,
  onIndex,
  onNarrate,
  onExit,
}: {
  steps: Step[];
  index: number;
  pending: boolean;
  pen: string;
  narrate: boolean;
  onIndex: (i: number) => void;
  onNarrate: () => void;
  onExit: () => void;
}) {
  const step = steps[index];
  const last = index >= steps.length - 1;
  return (
    <View style={styles.wrap}>
      <View style={styles.head}>
        <Text style={styles.kicker}>STEP</Text>
        <RollingNumber value={index + 1} style={[styles.count, { color: pen }]} lineHeight={18} />
        <Text style={styles.of}>/</Text>
        <RollingNumber value={steps.length} style={styles.count} lineHeight={18} />
        {pending ? <ShinyText text=" writing…" style={styles.writing} /> : null}
        <View style={{ flex: 1 }} />
        <PressScale onPress={onNarrate} accessibilityRole="button" accessibilityLabel={narrate ? 'Stop reading steps aloud' : 'Read steps aloud'} scaleTo={0.85} hitSlop={8}>
          <View style={styles.iconBtn}>
            <Icon name={narrate ? 'voice' : 'voiceOff'} size={19} color={narrate ? paper : faint} />
          </View>
        </PressScale>
        <PressScale onPress={onExit} accessibilityRole="button" accessibilityLabel="Leave walkthrough" scaleTo={0.85} hitSlop={8}>
          <View style={styles.iconBtn}>
            <Icon name="close" size={18} color={mist} />
          </View>
        </PressScale>
      </View>

      <Segments n={Math.max(steps.length, 1)} index={index} pen={pen} />

      <View style={styles.body}>
        {step ? <BlurText key={step.id} text={step.text} style={styles.text} step={45} duration={560} /> : <ShinyText text="Working out the steps" style={styles.text} />}
      </View>

      <View style={styles.controls}>
        <PressScale onPress={() => onIndex(Math.max(0, index - 1))} disabled={index === 0} accessibilityRole="button" accessibilityLabel="Previous step" scaleTo={0.88}>
          <View style={[styles.prev, index === 0 && { opacity: 0.35 }]}>
            <Icon name="left" size={22} />
          </View>
        </PressScale>
        <PressScale
          onPress={() => (last && !pending ? onExit() : onIndex(Math.min(steps.length - 1, index + 1)))}
          disabled={last && pending}
          accessibilityRole="button"
          accessibilityLabel={last && !pending ? 'Finish' : 'Next step'}
          scaleTo={0.94}
          haptic="medium"
          style={{ flex: 1 }}
        >
          <View style={[styles.next, { backgroundColor: pen }, last && pending && { opacity: 0.5 }]}>
            <Animated.Text key={last && !pending ? 'done' : 'next'} entering={FadeIn.duration(180)} style={styles.nextText}>
              {last && !pending ? 'Done' : 'Next'}
            </Animated.Text>
            <Icon name={last && !pending ? 'check' : 'right'} size={20} color={ink} stroke={2.3} />
          </View>
        </PressScale>
      </View>
    </View>
  );
}

function Segments({ n, index, pen }: { n: number; index: number; pen: string }) {
  return (
    <View style={styles.segments}>
      {Array.from({ length: n }, (_, i) => (
        <Segment key={i} on={i <= index} current={i === index} pen={pen} />
      ))}
    </View>
  );
}

function Segment({ on, current, pen }: { on: boolean; current: boolean; pen: string }) {
  const f = useSharedValue(on ? 1 : 0);
  useEffect(() => {
    f.value = withSpring(on ? 1 : 0, springs.arrive);
  }, [on, f]);
  const a = useAnimatedStyle(() => ({ transform: [{ scaleX: f.value }] }));
  return (
    <View style={[styles.segment, current && { flex: 1.6 }]}>
      <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: pen, transformOrigin: 'left center' }, a]} />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { gap: 12 },
  head: { flexDirection: 'row', alignItems: 'center', gap: 6, height: 30 },
  kicker: { color: faint, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.6 },
  count: { color: paper, fontFamily: fonts.mono, fontSize: 15, letterSpacing: 0.5 },
  of: { color: faint, fontFamily: fonts.mono, fontSize: 15 },
  writing: { color: mist, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 0.6 },
  iconBtn: { width: 34, height: 34, borderRadius: 17, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(244,241,234,0.07)' },
  segments: { flexDirection: 'row', gap: 4, height: 4 },
  segment: { flex: 1, height: 4, borderRadius: 2, overflow: 'hidden', backgroundColor: 'rgba(244,241,234,0.12)' },
  body: { minHeight: 58, justifyContent: 'center' },
  text: { color: paper, fontFamily: fonts.displayBold, fontSize: 21, lineHeight: 26, letterSpacing: -0.4 },
  controls: { flexDirection: 'row', gap: 10, alignItems: 'center' },
  prev: { width: 52, height: 52, borderRadius: 26, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(244,241,234,0.08)' },
  next: { height: 52, borderRadius: 26, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6 },
  nextText: { color: ink, fontFamily: fonts.display, fontSize: 18, letterSpacing: -0.3 },
});

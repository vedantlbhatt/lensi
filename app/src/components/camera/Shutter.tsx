import * as Haptics from 'expo-haptics';
import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  Easing,
  cancelAnimation,
  interpolate,
  interpolateColor,
  useAnimatedProps,
  useAnimatedStyle,
  useSharedValue,
  withSequence,
  withSpring,
  withTiming,
} from 'react-native-reanimated';
import Svg, { Circle } from 'react-native-svg';

import { getSettings } from '../../lib/settings';
import { springs, calm } from '../../theme/motion';
import { paper, record } from '../../theme/tokens';
import { face } from '../../theme/type';

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

export const SHUTTER = 84;
const DISC = 66;
const RING = 4.5;
export const MAX_RECORD_MS = 15_000;
const HOLD_MS = 280;

/**
 * Tap for a photo, hold for video (up to 15 s), like every camera people
 * already know. While recording the ring swells, a red arc fills around it,
 * and the disc folds into a rounded stop square.
 */
export function Shutter({
  pen,
  disabled,
  onPhoto,
  onRecordStart,
  onRecordStop,
}: {
  pen: string;
  disabled?: boolean;
  onPhoto: () => void;
  onRecordStart: () => Promise<boolean>;
  onRecordStop: () => void;
}) {
  const press = useSharedValue(0);
  const rec = useSharedValue(0);
  const progress = useSharedValue(0);
  const tint = useSharedValue(0);
  const [recording, setRecording] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const started = useRef(0);
  const prevPen = useRef(pen);
  const [colors, setColors] = useState({ from: pen, to: pen });

  // Cross-fade the disc between lens pens instead of snapping.
  useEffect(() => {
    if (prevPen.current === pen) return;
    setColors({ from: prevPen.current, to: pen });
    prevPen.current = pen;
    tint.value = 0;
    tint.value = withTiming(1, { duration: 260, easing: Easing.out(Easing.quad) });
  }, [pen, tint]);

  useEffect(() => {
    if (!recording) return;
    const t = setInterval(() => {
      const ms = Date.now() - started.current;
      setElapsed(ms);
      if (ms >= MAX_RECORD_MS) stop();
    }, 200);
    return () => clearInterval(t);
    // stop is stable enough for this interval's lifetime
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [recording]);

  const haptic = (style: Haptics.ImpactFeedbackStyle) => {
    if (getSettings().haptics) Haptics.impactAsync(style).catch(() => {});
  };

  const start = async () => {
    rec.value = withSpring(1, springs.arrive);
    haptic(Haptics.ImpactFeedbackStyle.Medium);
    const ok = await onRecordStart();
    if (!ok) {
      rec.value = withSpring(0, springs.snap);
      return;
    }
    started.current = Date.now();
    setElapsed(0);
    setRecording(true);
    progress.value = 0;
    progress.value = withTiming(1, { duration: MAX_RECORD_MS, easing: Easing.linear });
  };

  function stop() {
    if (!started.current) return;
    started.current = 0;
    setRecording(false);
    cancelAnimation(progress);
    progress.value = withTiming(0, { duration: 240 });
    rec.value = withSpring(0, springs.arrive);
    haptic(Haptics.ImpactFeedbackStyle.Light);
    onRecordStop();
  }

  const tap = Gesture.Tap()
    .maxDuration(HOLD_MS)
    .enabled(!disabled)
    .runOnJS(true)
    .onBegin(() => {
      press.value = withSpring(1, springs.press);
    })
    .onEnd((_e, ok) => {
      if (!ok) return;
      press.value = withSequence(withTiming(1, { duration: 50 }), withSpring(0, calm({ ...springs.press, damping: 8 })));
      haptic(Haptics.ImpactFeedbackStyle.Medium);
      onPhoto();
    })
    .onFinalize(() => {
      press.value = withSpring(0, springs.press);
    });

  const hold = Gesture.LongPress()
    .minDuration(HOLD_MS)
    .maxDistance(120)
    .enabled(!disabled)
    .runOnJS(true)
    .onStart(() => {
      void start();
    })
    .onFinalize(() => {
      stop();
    });

  const ring = useAnimatedStyle(() => ({
    transform: [{ scale: interpolate(rec.value, [0, 1], [1, 1.26]) * (1 - press.value * 0.06) }],
    borderColor: interpolateColor(rec.value, [0, 1], [paper, 'rgba(255,255,255,0.28)']),
  }));
  const disc = useAnimatedStyle(() => {
    const size = interpolate(rec.value, [0, 1], [DISC, 30]);
    return {
      width: size,
      height: size,
      borderRadius: interpolate(rec.value, [0, 1], [DISC / 2, 9]),
      backgroundColor:
        rec.value > 0.01
          ? interpolateColor(rec.value, [0, 1], [colors.to, record])
          : interpolateColor(tint.value, [0, 1], [colors.from, colors.to]),
      transform: [{ scale: 1 - press.value * 0.14 }],
    };
  }, [colors]);
  const arcR = SHUTTER / 2 + 9;
  const C = 2 * Math.PI * arcR;
  const arc = useAnimatedProps(() => ({
    strokeDashoffset: C * (1 - progress.value),
    opacity: rec.value,
  }));
  const timer = useAnimatedStyle(() => ({
    opacity: rec.value,
    transform: [{ translateY: interpolate(rec.value, [0, 1], [10, 0]) }],
  }));

  const secs = Math.min(MAX_RECORD_MS, elapsed) / 1000;
  return (
    <View style={styles.wrap} accessibilityRole="button" accessibilityLabel="Shutter. Tap for a photo, hold to record video.">
      <Animated.View style={[styles.timer, timer]} pointerEvents="none">
        <Text style={styles.timerText}>{`0:${String(Math.floor(secs)).padStart(2, '0')}`}</Text>
      </Animated.View>
      <Svg width={arcR * 2 + 8} height={arcR * 2 + 8} style={styles.arc} pointerEvents="none">
        <AnimatedCircle
          cx={arcR + 4}
          cy={arcR + 4}
          r={arcR}
          stroke={record}
          strokeWidth={4}
          strokeLinecap="round"
          fill="none"
          strokeDasharray={`${C} ${C}`}
          animatedProps={arc}
          transform={`rotate(-90 ${arcR + 4} ${arcR + 4})`}
        />
      </Svg>
      <GestureDetector gesture={Gesture.Exclusive(hold, tap)}>
        <Animated.View style={[styles.ring, ring]} collapsable={false}>
          <Animated.View style={disc} />
        </Animated.View>
      </GestureDetector>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { width: SHUTTER + 40, height: SHUTTER + 40, alignItems: 'center', justifyContent: 'center' },
  ring: {
    width: SHUTTER,
    height: SHUTTER,
    borderRadius: SHUTTER / 2,
    borderWidth: RING,
    alignItems: 'center',
    justifyContent: 'center',
  },
  arc: { position: 'absolute' },
  timer: {
    position: 'absolute',
    top: -34,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 9,
    height: 24,
    borderRadius: 6,
    borderCurve: 'continuous',
    backgroundColor: record,
  },
  timerText: { color: '#FFFFFF', ...face.semibold, fontSize: 14, fontVariant: ['tabular-nums'] },
});

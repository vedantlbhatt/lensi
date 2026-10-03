import { Image } from 'expo-image';
import { forwardRef, useEffect, useImperativeHandle, useState } from 'react';
import { StyleSheet, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  Easing,
  FadeIn,
  FadeOut,
  interpolate,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withSequence,
  withTiming,
} from 'react-native-reanimated';

import { DEMO_SCENES, type DemoScene } from '../../../modules/lensi-ar/src';
import { boxToView, fitRect } from '../../lib/geometry';
import { assetPhoto, type Picked } from '../../lib/media';
import { Grain } from '../../motion/Grain';
import type { CameraHandle } from './CameraSurface';

/**
 * Stand-in camera for the Simulator and the web preview: the demo scenes,
 * drifting slowly like a handheld shot, with live-style brackets on the
 * subject. Swipe sideways for the next scene.
 */
export const VirtualCamera = forwardRef<
  CameraHandle,
  { pen: string; brackets: boolean; onScene?: (s: DemoScene) => void }
>(function VirtualCamera({ pen, brackets, onScene }, ref) {
  const { width, height } = useWindowDimensions();
  const [index, setIndex] = useState(0);
  const scene = DEMO_SCENES[index];

  useEffect(() => {
    onScene?.(scene);
  }, [scene, onScene]);

  useImperativeHandle(
    ref,
    () => ({
      takePhoto: async (): Promise<Picked> => assetPhoto(scene.asset, scene.width, scene.height),
      startRecording: async () => false,
      stopRecording: async () => null,
      setTorch: async () => false,
    }),
    [scene],
  );

  const drift = useSharedValue(0);
  useEffect(() => {
    drift.value = withRepeat(withTiming(1, { duration: 9000, easing: Easing.inOut(Easing.sin) }), -1, true);
  }, [drift]);
  const kb = useAnimatedStyle(() => ({
    transform: [
      { scale: interpolate(drift.value, [0, 1], [1.02, 1.065]) },
      { translateX: interpolate(drift.value, [0, 1], [-5, 6]) },
      { translateY: interpolate(drift.value, [0, 1], [4, -3]) },
    ],
  }));

  const swipe = Gesture.Pan()
    .activeOffsetX([-24, 24])
    .runOnJS(true)
    .onEnd((e) => {
      if (Math.abs(e.translationX) < 60) return;
      const dir = e.translationX < 0 ? 1 : -1;
      setIndex((i) => (i + dir + DEMO_SCENES.length) % DEMO_SCENES.length);
    });

  const fit = fitRect(scene.width, scene.height, width, height, 'cover');
  const b = boxToView({ x: scene.outline.box[0], y: scene.outline.box[1], w: scene.outline.box[2], h: scene.outline.box[3] }, fit);

  return (
    <GestureDetector gesture={swipe}>
      <View style={StyleSheet.absoluteFill} collapsable={false}>
        <Animated.View key={scene.key} entering={FadeIn.duration(380)} exiting={FadeOut.duration(260)} style={[StyleSheet.absoluteFill, kb]}>
          <Image source={scene.asset} style={StyleSheet.absoluteFill} contentFit="cover" transition={0} />
        </Animated.View>
        <Grain opacity={0.05} />
        {brackets ? <Brackets key={`b-${scene.key}`} x={b.x} y={b.y} w={b.w} h={b.h} pen={pen} /> : null}
      </View>
    </GestureDetector>
  );
});

/** Corner brackets that settle onto the subject, then breathe. */
function Brackets({ x, y, w, h, pen }: { x: number; y: number; w: number; h: number; pen: string }) {
  const t = useSharedValue(0);
  const breathe = useSharedValue(0);
  useEffect(() => {
    t.value = withTiming(1, { duration: 700, easing: Easing.bezier(0.16, 1, 0.3, 1) });
    breathe.value = withRepeat(withSequence(withTiming(1, { duration: 1400 }), withTiming(0, { duration: 1400 })), -1);
  }, [t, breathe]);
  const inset = 6;
  const L = Math.min(26, w / 4, h / 4);
  const corner = (cx: number, cy: number, sx: 1 | -1, sy: 1 | -1, i: number) => (
    <Corner key={i} cx={cx} cy={cy} sx={sx} sy={sy} L={L} pen={pen} t={t} breathe={breathe} />
  );
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      {corner(x - inset, y - inset, 1, 1, 0)}
      {corner(x + w + inset, y - inset, -1, 1, 1)}
      {corner(x - inset, y + h + inset, 1, -1, 2)}
      {corner(x + w + inset, y + h + inset, -1, -1, 3)}
    </View>
  );
}

function Corner({
  cx,
  cy,
  sx,
  sy,
  L,
  pen,
  t,
  breathe,
}: {
  cx: number;
  cy: number;
  sx: 1 | -1;
  sy: 1 | -1;
  L: number;
  pen: string;
  t: ReturnType<typeof useSharedValue<number>>;
  breathe: ReturnType<typeof useSharedValue<number>>;
}) {
  const a = useAnimatedStyle(() => {
    // Start pushed outward and settle in; then a 3px breath.
    const out = (1 - t.value) * 28 + breathe.value * 3;
    return {
      opacity: t.value,
      transform: [{ translateX: cx - sx * out }, { translateY: cy - sy * out }],
    };
  });
  const S = 3;
  return (
    <Animated.View style={[styles.corner, a]}>
      <View style={[styles.bar, { backgroundColor: pen, width: L, height: S, left: sx === 1 ? -S / 2 : -L + S / 2, top: -S / 2 }]} />
      <View style={[styles.bar, { backgroundColor: pen, width: S, height: L, left: -S / 2, top: sy === 1 ? -S / 2 : -L + S / 2 }]} />
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  corner: { position: 'absolute', left: 0, top: 0, width: 0, height: 0 },
  bar: {
    position: 'absolute',
    borderRadius: 2,
    shadowColor: '#000',
    shadowOpacity: 0.35,
    shadowRadius: 4,
    shadowOffset: { width: 0, height: 1 },
  },
});

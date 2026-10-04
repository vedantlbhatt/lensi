import { Image } from 'expo-image';
import { forwardRef, useEffect, useImperativeHandle, useState } from 'react';
import { StyleSheet, useWindowDimensions, View } from 'react-native';
import Svg, { Polygon } from 'react-native-svg';
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

import { DEMO_SCENES, setDemoQuestion, type DemoScene, type ZoomRange } from '../../../modules/lensi-ar/src';
import { boxToView, fitRect, smallestShapeAt, toView, type Fit } from '../../lib/geometry';
import type { GuidePart } from '../../lib/guide';
import { assetPhoto, type Picked } from '../../lib/media';
import { Grain } from '../../motion/Grain';
import { face } from '../../theme/type';
import { labelWidth } from '../capture/layout';
import type { CameraHandle, VirtualGuidePins } from './CameraSurface';

export type VirtualHandle = Pick<CameraHandle, 'takePhoto' | 'startRecording' | 'stopRecording' | 'setTorch' | 'nextScene' | 'setZoom' | 'outlineAt'>;

/**
 * The virtual camera crops into its scene the way the real one does above 1x. There's no
 * 0.5x: a still photo has nothing wider to show (it would only shrink into a black frame),
 * the same as a phone without an ultra-wide camera.
 */
const ZOOM: ZoomRange = { min: 1, max: 10, zoom: 1 };

/**
 * Stand-in camera for the Simulator and the web preview: the demo scenes,
 * drifting slowly like a handheld shot, with live-style brackets on the
 * subject. Swipe sideways for the next scene.
 */
export const VirtualCamera = forwardRef<
  VirtualHandle,
  {
    pen: string;
    brackets: boolean;
    liveOutlines?: boolean;
    onScene?: (s: DemoScene) => void;
    onZoomRange?: (r: ZoomRange) => void;
    guidePins?: VirtualGuidePins;
    sceneKey?: string;
  }
>(function VirtualCamera({ pen, brackets, liveOutlines, onScene, onZoomRange, guidePins, sceneKey }, ref) {
  const { width, height } = useWindowDimensions();
  const [index, setIndex] = useState(0);
  const [zoom, setZoom] = useState(1);
  /** What a tap asked to have outlined (scene 0-1 space), like the phone's tap-to-outline. */
  const [tapped, setTapped] = useState<{ x: number; y: number }[] | null>(null);
  useEffect(() => {
    onZoomRange?.(ZOOM);
  }, [onZoomRange]);
  const scene = DEMO_SCENES[index];
  // Scripted runs pick the scene (lensi:///?scene=truck).
  useEffect(() => {
    const i = DEMO_SCENES.findIndex((s) => s.key === sceneKey);
    if (i >= 0) setIndex(i);
  }, [sceneKey]);

  useEffect(() => {
    onScene?.(scene);
    setDemoQuestion(scene.script.question);
    setTapped(null);
  }, [scene, onScene]);

  // Zoom scales the scene about the screen's centre; tags and outlines are
  // placed on the zoomed scene but keep their size.
  const cover = fitRect(scene.width, scene.height, width, height, 'cover');
  const fit = {
    x: width / 2 + (cover.x - width / 2) * zoom,
    y: height / 2 + (cover.y - height / 2) * zoom,
    w: cover.w * zoom,
    h: cover.h * zoom,
  };

  useImperativeHandle(
    ref,
    () => ({
      takePhoto: async (): Promise<Picked> => assetPhoto(scene.asset, scene.width, scene.height),
      startRecording: async () => false,
      stopRecording: async () => null,
      setTorch: async () => false,
      nextScene: (dir: 1 | -1) => setIndex((i) => (i + dir + DEMO_SCENES.length) % DEMO_SCENES.length),
      setZoom: (z: number) => setZoom(Math.min(ZOOM.max, Math.max(ZOOM.min, z))),
      // The smallest of the scene's real SAM shapes under the finger (its parts, then the
      // subject); a tap on none of them goes back to outlining the subject.
      outlineAt: (x: number, y: number) => {
        if (guidePins?.parts.length) return;
        const at = { x: (x - fit.x) / fit.w, y: (y - fit.y) / fit.h };
        const shapes = [...scene.parts.map((p) => p.polygon), scene.outline.polygon].map((poly) => poly.map(([px, py]) => ({ x: px, y: py })));
        setTapped(smallestShapeAt(at, shapes));
      },
    }),
    [scene, fit.x, fit.y, fit.w, fit.h, guidePins?.parts.length],
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

  const raw = boxToView({ x: scene.outline.box[0], y: scene.outline.box[1], w: scene.outline.box[2], h: scene.outline.box[3] }, fit);
  // Keep every corner on screen: a bracket half off the edge reads as a stray mark.
  // Symmetric side margins that clear the tool rail on the right.
  const m = 22;
  const side = 66;
  const x0 = Math.max(side, raw.x);
  const y0 = Math.max(m + 90, raw.y);
  const x1 = Math.min(width - side, raw.x + raw.w);
  const y1 = Math.min(height - m - 230, raw.y + raw.h);
  const b = { x: x0, y: y0, w: Math.max(40, x1 - x0), h: Math.max(40, y1 - y0) };

  return (
    <View style={StyleSheet.absoluteFill} collapsable={false}>
      <Animated.View key={scene.key} entering={FadeIn.duration(380)} exiting={FadeOut.duration(260)} style={[StyleSheet.absoluteFill, kb]}>
        <Image source={scene.asset} style={{ position: 'absolute', left: fit.x, top: fit.y, width: fit.w, height: fit.h }} contentFit="fill" transition={0} />
        {/* Inside the drifting layer, so the outline and tags ride the scene like pins on a real camera. */}
        {/* Live outline of what's in view, as the phone's live SAM draws it (the scene's real SAM outline). */}
        {liveOutlines && !guidePins?.parts.length ? (
          <GuideOutline
            key={`live-${scene.key}-${tapped ? tapped.length + ':' + tapped[0].x.toFixed(3) : 'subject'}`}
            part={{ id: 'live', label: '', at: { x: 0.5, y: 0.5 }, outline: tapped ?? scene.outline.polygon.map(([x, y]) => ({ x, y })) }}
            fit={fit}
            pen={pen}
            focused={false}
            strong
          />
        ) : null}
        {guidePins?.parts.map((p) => <GuideOutline key={`o-${p.id}`} part={p} fit={fit} pen={pen} focused={guidePins.focus === p.id} />)}
        {guidePins?.parts.map((p) => <GuideTag key={p.id} part={p} fit={fit} pen={pen} focus={guidePins.focus} screenW={width} />)}
      </Animated.View>
      <Grain opacity={0.05} />
      {brackets && !liveOutlines && !guidePins?.parts.length ? <Brackets key={`b-${scene.key}`} x={b.x} y={b.y} w={b.w} h={b.h} pen={pen} /> : null}
    </View>
  );
});

/**
 * A part's outline: the current step's in the lens colour, the rest thin and white, each
 * over a faint dark halo so it still reads where the part is as pale as the line (the same
 * look as the phone's live outlines).
 */
function GuideOutline({ part, fit, pen, focused, strong }: { part: GuidePart; fit: Fit; pen: string; focused: boolean; strong?: boolean }) {
  if (!part.outline) return null;
  const points = part.outline.map((q) => toView(q, fit)).map((q) => `${q.x.toFixed(1)},${q.y.toFixed(1)}`).join(' ');
  const color = focused ? pen : '#FFFFFF';
  const bold = focused || strong;
  const width = focused ? 2.5 : bold ? 2 : 1.5;
  return (
    <Animated.View entering={FadeIn.duration(220)} exiting={FadeOut.duration(160)} style={StyleSheet.absoluteFill} pointerEvents="none">
      <Svg width="100%" height="100%" style={StyleSheet.absoluteFill}>
        <Polygon points={points} fill="none" stroke="#000000" strokeOpacity={0.32} strokeWidth={width + 2.5} strokeLinejoin="round" />
        <Polygon
          points={points}
          fill={color}
          fillOpacity={focused ? 0.14 : bold ? 0.07 : 0.06}
          stroke={color}
          strokeOpacity={bold ? 1 : 0.75}
          strokeWidth={width}
          strokeLinejoin="round"
        />
      </Svg>
    </Animated.View>
  );
}

/** A live-guide tag on the virtual scene: white, or on the lens colour when its step is current. */
function GuideTag({ part, fit, pen, focus, screenW }: { part: GuidePart; fit: Fit; pen: string; focus: string | null; screenW: number }) {
  const at = toView(part.at, fit);
  // A part near the edge keeps its whole tag on screen.
  const half = labelWidth(part.label) / 2 + 10;
  at.x = Math.min(screenW - half, Math.max(half, at.x));
  const focused = focus === part.id;
  const dimmed = focus !== null && !focused;
  return (
    <Animated.View
      entering={FadeIn.duration(260)}
      style={[styles.tagSlot, { left: at.x - 90, top: at.y - 13 }, dimmed && styles.dimmed]}
      pointerEvents="none"
    >
      <View style={[styles.tag, focused && { backgroundColor: pen }]}>
        <Animated.Text style={styles.tagText} numberOfLines={1}>
          {part.label}
        </Animated.Text>
      </View>
    </Animated.View>
  );
}

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
  tagSlot: { position: 'absolute', width: 180, height: 26, alignItems: 'center', justifyContent: 'center' },
  dimmed: { opacity: 0.55 },
  tag: {
    height: 26,
    paddingHorizontal: 9,
    borderRadius: 7,
    borderCurve: 'continuous',
    justifyContent: 'center',
    backgroundColor: '#FFFFFF',
    shadowColor: '#000',
    shadowOpacity: 0.28,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 },
  },
  tagText: { color: '#000000', ...face.semibold, fontSize: 13, letterSpacing: -0.08 },
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

import { Image } from 'expo-image';
import { useVideoPlayer, VideoView } from 'expo-video';
import { forwardRef, useCallback, useEffect, useImperativeHandle, useMemo, useReducer, useRef, useState } from 'react';
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

import { Asset } from 'expo-asset';
import { DEMO_SCENES, DemoVideoView, onSceneTracks, sceneTracks, setDemoQuestion, type DemoScene, type VideoTracks, type ZoomRange } from '../../../modules/lensi-ar/src';
import { boxToView, centroid, fitRect, pointInPolygon, polygonIoU, toView, type Fit } from '../../lib/geometry';
import type { GuidePart } from '../../lib/guide';
import type { Pt } from '../../lib/types';
import { assetPhoto, type Picked } from '../../lib/media';
import { Grain } from '../../motion/Grain';
import { face } from '../../theme/type';
import { labelWidth } from '../capture/layout';
import type { CameraHandle, VirtualGuidePins } from './CameraSurface';

export type VirtualHandle = Pick<CameraHandle, 'takePhoto' | 'startRecording' | 'stopRecording' | 'setTorch' | 'nextScene' | 'setZoom' | 'scrub'>;

/**
 * Something the strip can pick on a demo scene, in scene coordinates (0-1). On a video scene it's
 * one of the tracked things (`track`), and its outline is wherever that is in the frame showing.
 */
type Thing = { label: string; polygon: Pt[]; track?: number };
type Pinned = Thing & { id: string };
/** The strip while a finger is on it: the things it found, the highlighted one, the ones pinned this time. */
type Strip = { things: Thing[]; index: number; pinned: number[] };

/** YOLO's name, as the strip shows it. */
const nameOf = (label: string | null) => (label ? label.charAt(0).toUpperCase() + label.slice(1) : null);

const decoded = new Map<string, Uint16Array>();
/** A tracked thing's outline in frame `f` of a video scene (tools/strip/pack.py's format), or null before it's found. */
export function outlineAt(tracks: VideoTracks, i: number, f: number): Pt[] | null {
  const th = tracks.things[i];
  if (!th || f < th.start) return null;
  let words = decoded.get(th.data);
  if (!words) {
    const bin = atob(th.data);
    const bytes = new Uint8Array(bin.length);
    for (let k = 0; k < bin.length; k++) bytes[k] = bin.charCodeAt(k);
    words = new Uint16Array(bytes.buffer, 0, bytes.length >> 1);
    decoded.set(th.data, words);
  }
  const n = tracks.points;
  const at = (f - th.start) * n * 2;
  if (at + n * 2 > words.length) return null;
  // All zeros: not in view at that frame (the app's own EdgeTAM run marks those so).
  let any = false;
  for (let k = at; k < at + n * 2 && !any; k++) any = words[k] !== 0;
  if (!any) return null;
  const pts: Pt[] = [];
  for (let k = 0; k < n; k++) pts.push({ x: words[at + 2 * k] / 65535, y: words[at + 2 * k + 1] / 65535 });
  return pts;
}

/**
 * A video scene's footage: it plays on a loop, and says which frame is showing (the tracks are
 * frame by frame).
 */
function SceneVideo({ source, fit, fps, frames, onFrame }: { source: number; fit: Fit; fps: number; frames: number; onFrame: (f: number) => void }) {
  const player = useVideoPlayer(source, (p) => {
    p.loop = true;
    p.muted = true;
    p.play();
  });
  // Again once the view is up: on the web the player only drives the video elements it has.
  useEffect(() => {
    player.play();
  }, [player]);
  useEffect(() => {
    let raf = 0;
    let last = -1;
    const tick = () => {
      const f = Math.min(frames - 1, Math.max(0, Math.floor((player.currentTime || 0) * fps)));
      if (f !== last) {
        last = f;
        onFrame(f);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [player, fps, frames, onFrame]);
  return (
    <VideoView
      player={player}
      style={{ position: 'absolute', left: fit.x, top: fit.y, width: fit.w, height: fit.h }}
      contentFit="fill"
      nativeControls={false}
    />
  );
}

/**
 * What the strip can pick on a demo scene: its parts (real MobileSAM shapes), each named by the
 * callout on it, and the whole subject; the same shape twice is kept once.
 */
function sceneThings(scene: DemoScene): Thing[] {
  const things: Thing[] = [];
  const add = (polygon: Pt[], label: string) => {
    if (polygon.length < 3 || things.some((t) => polygonIoU(t.polygon, polygon) > 0.6)) return;
    things.push({ label, polygon });
  };
  for (const p of scene.parts) {
    const polygon = p.polygon.map(([x, y]) => ({ x, y }));
    const named =
      scene.script.callouts.find((c) => Math.hypot(c.at[0] - p.at[0], c.at[1] - p.at[1]) < 0.03) ??
      scene.script.callouts.find((c) => pointInPolygon({ x: c.at[0], y: c.at[1] }, polygon));
    add(polygon, p.label ?? named?.label ?? 'Part');
  }
  add(scene.outline.polygon.map(([x, y]) => ({ x, y })), scene.script.title);
  return things;
}

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
  // The strip, as the phone's: the things found when the finger landed, and what's pinned
  // (pins ride the scene, as the phone's stay on their things).
  const [strip, setStrip] = useState<Strip | null>(null);
  const stripRef = useRef<Strip | null>(null);
  const [pinned, setPinned] = useState<Pinned[]>([]);
  const pinnedRef = useRef<Pinned[]>([]);
  const putStrip = (s: Strip | null) => {
    stripRef.current = s;
    setStrip(s);
  };
  const putPinned = (p: Pinned[]) => {
    pinnedRef.current = p;
    setPinned(p);
  };
  useEffect(() => {
    onZoomRange?.(ZOOM);
  }, [onZoomRange]);
  const scene = DEMO_SCENES[index];
  const video = scene.video;
  // The bundled tracks, or the app's own EdgeTAM run's once it has one (`edgetam=`).
  const [, tracksChanged] = useReducer((n: number) => n + 1, 0);
  useEffect(() => onSceneTracks(tracksChanged), []);
  const tracks = video ? sceneTracks(scene) : null;
  // Which frame of a video scene is showing.
  const [frame, setFrame] = useState(0);
  const frameRef = useRef(0);
  // On iOS the footage and its pinned outlines are drawn natively, in the same display frame
  // (DemoVideoView): JavaScript only needs to know which frame is showing, for the strip.
  const native = !!video && !!DemoVideoView;
  const [videoUri, setVideoUri] = useState<string | null>(null);
  useEffect(() => {
    if (!native || !video) return;
    let alive = true;
    setVideoUri(null);
    const asset = Asset.fromModule(video.source);
    void asset.downloadAsync().then(() => {
      if (alive) setVideoUri(asset.localUri ?? asset.uri);
    });
    return () => {
      alive = false;
    };
  }, [native, video]);
  const tracksJson = useMemo(() => (tracks ? JSON.stringify(tracks) : ''), [tracks]);
  const onNativeFrame = useCallback((e: { nativeEvent: { frame: number } }) => {
    frameRef.current = e.nativeEvent.frame;
  }, []);
  const onFrame = useCallback((f: number) => {
    frameRef.current = f;
    setFrame(f);
  }, []);
  // Scripted runs pick the scene (lensi:///?scene=truck).
  useEffect(() => {
    const i = DEMO_SCENES.findIndex((s) => s.key === sceneKey);
    if (i >= 0) setIndex(i);
  }, [sceneKey]);

  useEffect(() => {
    onScene?.(scene);
    setDemoQuestion(scene.script.question);
    // Pins belong to the scene they were made on.
    putStrip(null);
    putPinned([]);
  }, [scene, onScene]);

  // Zoom scales the scene about the screen's centre; tags and outlines are
  // placed on the zoomed scene but keep their size. Landscape footage is shown across the screen
  // and a little more, above the chrome, the way a phone held upright shows a wide shot; a still,
  // or footage filmed upright, fills the screen.
  // Footage filmed upright fills the screen, as the camera does.
  const cover = video && scene.width > scene.height
    ? (() => {
        const s = (width / scene.width) * 1.3;
        return { x: (width - scene.width * s) / 2, y: height * 0.37 - (scene.height * s) / 2, w: scene.width * s, h: scene.height * s };
      })()
    : fitRect(scene.width, scene.height, width, height, 'cover');
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
      scrub: {
        // The scene's things whose middle is on screen between `top` and `bottom`, left to right.
        start: async (top: number, bottom: number) => {
          if (video) {
            // The tracked things where they are in the frame showing now.
            const f = frameRef.current;
            const here = (tracks?.things ?? [])
              .map((th, i) => ({ i, label: nameOf(th.label), polygon: tracks ? outlineAt(tracks, i, f) : null }))
              .filter((t): t is { i: number; label: string | null; polygon: Pt[] } => !!t.polygon)
              .map((t) => ({ ...t, at: toView(centroid(t.polygon), fit) }))
              .filter((t) => t.at.x > 0 && t.at.x < width && t.at.y > top && t.at.y < bottom)
              .sort((a, b) => a.at.x - b.at.x || a.at.y - b.at.y)
              .slice(0, 14);
            putStrip({ things: here.map((t) => ({ label: t.label ?? 'Thing', polygon: t.polygon, track: t.i })), index: -1, pinned: [] });
            return here.map((t) => ({ label: t.label }));
          }
          const found = sceneThings(scene)
            .map((t) => ({ ...t, at: toView(centroid(t.polygon), fit) }))
            .filter((t) => t.at.x > 0 && t.at.x < width && t.at.y > top && t.at.y < bottom)
            .sort((a, b) => a.at.x - b.at.x || a.at.y - b.at.y)
            .slice(0, 14);
          putStrip({ things: found.map(({ label, polygon }) => ({ label, polygon })), index: -1, pinned: [] });
          return found.map((t) => ({ label: t.label }));
        },
        to: (i: number) => {
          const s = stripRef.current;
          if (s) putStrip({ ...s, index: i });
        },
        pin: async (i: number) => {
          const s = stripRef.current;
          const t = s?.things[i];
          if (!s || !t) return null;
          putStrip({ ...s, pinned: [...s.pinned, i] });
          // Pinned before (an earlier touch): it stays the one pin.
          const same = pinnedRef.current.find((p) =>
            t.track !== undefined ? p.track === t.track : p.track === undefined && polygonIoU(p.polygon, t.polygon) > 0.8,
          );
          if (same) return same.id;
          const id = `pin-${Date.now().toString(36)}-${i}`;
          putPinned([...pinnedRef.current, { ...t, id }]);
          return id;
        },
        end: () => putStrip(null),
        clear: () => putPinned([]),
      },
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [scene, fit.x, fit.y, fit.w, fit.h, width, tracks],
  );
  // On a video scene a picked or pinned thing is wherever its track is in this frame.
  const shapeOf = (t: Thing): Pt[] | null => (t.track !== undefined && tracks ? outlineAt(tracks, t.track, frame) : t.polygon);

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
      <Animated.View key={scene.key} entering={FadeIn.duration(380)} exiting={FadeOut.duration(260)} style={[StyleSheet.absoluteFill, !video && kb]}>
        {video && native && DemoVideoView ? (
          videoUri ? (
            <DemoVideoView
              source={videoUri}
              tracks={tracksJson}
              pins={pinned.filter((p) => p.track !== undefined).map((p) => ({ track: p.track as number, color: pen, label: p.label }))}
              highlight={(() => {
                const i = strip?.index ?? -1;
                const t = strip && i >= 0 && !strip.pinned.includes(i) ? strip.things[i] : undefined;
                return t && t.track !== undefined ? { track: t.track, color: pen, label: t.label } : null;
              })()}
              onFrame={onNativeFrame}
              style={{ position: 'absolute', left: fit.x, top: fit.y, width: fit.w, height: fit.h }}
            />
          ) : null
        ) : video ? (
          <SceneVideo source={video.source} fit={fit} fps={tracks?.fps ?? 15} frames={tracks?.frames ?? 150} onFrame={onFrame} />
        ) : (
          <Image source={scene.asset} style={{ position: 'absolute', left: fit.x, top: fit.y, width: fit.w, height: fit.h }} contentFit="fill" transition={0} />
        )}
        {/* Inside the drifting layer, so the outline and tags ride the scene like pins on a real camera. */}
        {/* The strip's highlighted thing while a finger is on it, in the lens colour; nothing else. */}
        {(() => {
          const i = strip?.index ?? -1;
          const t = strip && i >= 0 && !strip.pinned.includes(i) ? strip.things[i] : undefined;
          const shape = t && !(native && t.track !== undefined) ? shapeOf(t) : null;
          return t && shape ? (
            <GuideOutline key={`s-${i}-${t.label}`} part={{ id: `s${i}`, label: t.label, at: { x: 0.5, y: 0.5 }, outline: shape }} fit={fit} pen={pen} focused />
          ) : null;
        })()}
        {/* Pinned things: outlined in the lens colour, named just above, wherever they've gone. */}
        {pinned.map((p) => {
          const shape = native && p.track !== undefined ? null : shapeOf(p);
          return shape ? <GuideOutline key={p.id} part={{ id: p.id, label: p.label, at: { x: 0.5, y: 0.5 }, outline: shape }} fit={fit} pen={pen} focused /> : null;
        })}
        {pinned.map((p) => {
          const shape = native && p.track !== undefined ? null : shapeOf(p);
          return shape ? <PinTag key={`t-${p.id}`} pin={{ ...p, polygon: shape }} fit={fit} pen={pen} screenW={width} /> : null;
        })}
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
function GuideOutline({
  part,
  fit,
  pen,
  focused,
  strong,
  faint,
}: {
  part: GuidePart;
  fit: Fit;
  pen: string;
  focused: boolean;
  strong?: boolean;
  /** The strip's other things: thin, with no fill. */
  faint?: boolean;
}) {
  if (!part.outline) return null;
  const points = part.outline.map((q) => toView(q, fit)).map((q) => `${q.x.toFixed(1)},${q.y.toFixed(1)}`).join(' ');
  const color = focused ? pen : '#FFFFFF';
  const bold = focused || strong;
  const width = focused ? 2.5 : bold ? 2 : faint ? 1.25 : 1.5;
  return (
    <Animated.View entering={FadeIn.duration(220)} exiting={FadeOut.duration(160)} style={StyleSheet.absoluteFill} pointerEvents="none">
      <Svg width="100%" height="100%" style={StyleSheet.absoluteFill}>
        <Polygon points={points} fill="none" stroke="#000000" strokeOpacity={0.32} strokeWidth={width + 2.5} strokeLinejoin="round" />
        <Polygon
          points={points}
          fill={color}
          fillOpacity={focused ? 0.14 : bold ? 0.07 : faint ? 0 : 0.06}
          stroke={color}
          strokeOpacity={bold ? 1 : faint ? 0.5 : 0.75}
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

/** A pinned thing's name, just above its outline, on the lens colour (as the phone draws it). */
function PinTag({ pin, fit, pen, screenW }: { pin: Pinned; fit: Fit; pen: string; screenW: number }) {
  const pts = pin.polygon.map((q) => toView(q, fit));
  const xs = pts.map((q) => q.x);
  const top = Math.min(...pts.map((q) => q.y));
  const half = (labelWidth(pin.label) * 16) / 13 / 2 + 14;
  const x = Math.min(screenW - half, Math.max(half, (Math.min(...xs) + Math.max(...xs)) / 2));
  return (
    <Animated.View entering={FadeIn.duration(240)} style={[styles.pinSlot, { left: x - 130, top: Math.max(4, top - 40) }]} pointerEvents="none">
      <View style={[styles.pinTag, { backgroundColor: pen }]}>
        <Animated.Text style={styles.pinText} numberOfLines={1}>
          {pin.label}
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
  pinSlot: { position: 'absolute', width: 260, height: 32, alignItems: 'center', justifyContent: 'center' },
  pinTag: {
    height: 32,
    paddingHorizontal: 12,
    borderRadius: 10,
    borderCurve: 'continuous',
    justifyContent: 'center',
    shadowColor: '#000',
    shadowOpacity: 0.3,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 3 },
  },
  pinText: { color: '#000000', ...face.bold, fontSize: 16, letterSpacing: -0.2 },
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

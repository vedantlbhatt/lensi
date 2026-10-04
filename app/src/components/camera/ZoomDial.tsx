import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Platform, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { useAnimatedStyle, useSharedValue, withTiming, type SharedValue } from 'react-native-reanimated';
import Svg, { Line, Path, Text as SvgText } from 'react-native-svg';

import { haptic } from '../../lib/haptics';
import { nextZoomStop, zoomAfterDrag, zoomText } from '../../lib/strip';
import { face } from '../../theme/type';

/** The numbers written on the dial (the ends are clamped to what the camera can do). */
const NUMBERS = [0.5, 1, 2, 3, 5, 10];
/** Degrees the dial turns per e-fold of zoom: 1x to 2x is 50 degrees, .5x to 10x 216. */
const DEG = 72;
/** After the finger lifts, the dial stays up this long (ms), then the button comes back. */
const LINGER = 1200;

/** Ticks every .05 below 1x, .1 to 2x, .2 to 5x, .5 above. */
function tickValues(min: number, max: number): { z: number; major: boolean }[] {
  const out: { z: number; major: boolean }[] = [];
  const add = (from: number, to: number, step: number) => {
    for (let z = from; z < to - 1e-6; z += step) out.push({ z: Math.round(z * 100) / 100, major: false });
  };
  add(0.5, 1, 0.05);
  add(1, 2, 0.1);
  add(2, 5, 0.2);
  add(5, 10.001, 0.5);
  return out
    .filter((t) => t.z >= min - 1e-6 && t.z <= max + 1e-6)
    .map((t) => ({ z: t.z, major: NUMBERS.some((n) => Math.abs(n - t.z) < 1e-6) }));
}

/**
 * The Camera app's zoom: one button with the zoom on it (.5×, 1×, 2.7×). Drag across it and a
 * dial rises over the camera, its ticks round a half circle turning under the finger; let go
 * and the zoom stays exactly where it stopped. A tap goes to the next stop (.5, 1, 2, 5). A
 * pinch on the camera turns the same dial (`turning`).
 */
export function ZoomDial({
  value,
  zoom,
  min,
  max,
  pen,
  onZoom,
  turning = false,
  demo,
  onOpen,
  hidden = false,
}: {
  /** The zoom now, exactly (the dial turns with it on the UI thread). */
  value: SharedValue<number>;
  /** The zoom to a tenth, for the button's label. */
  zoom: number;
  min: number;
  max: number;
  pen: string;
  onZoom: (z: number) => void;
  /** A pinch is zooming: the dial shows. */
  turning?: boolean;
  /** Scripted runs (CI, the web demo): turn the dial to this zoom by itself, and leave it up. */
  demo?: number;
  /** The dial is up (the chrome under it steps aside). */
  onOpen?: (open: boolean) => void;
  /** Out of the way (a finger is on the strip below). */
  hidden?: boolean;
}) {
  const { width } = useWindowDimensions();
  const R = Math.round(width * 0.62);
  // The dial is the top of a circle whose chord is the screen's width.
  const H = R - Math.sqrt(R * R - (width / 2) * (width / 2));
  const TOP = 34;
  const BAND = 58;
  const cy = TOP + R;
  const ticks = useMemo(() => tickValues(min, max), [min, max]);

  const [open, setOpen] = useState(false);
  const shown = useSharedValue(0);
  const close = useRef<ReturnType<typeof setTimeout> | null>(null);
  const hold = useRef(false);
  const opened = useRef(onOpen);
  opened.current = onOpen;
  const show = useCallback(() => {
    if (close.current) clearTimeout(close.current);
    close.current = null;
    setOpen(true);
    opened.current?.(true);
    shown.value = withTiming(1, { duration: 160 });
  }, [shown]);
  const hide = useCallback(
    (after = LINGER) => {
      if (close.current) clearTimeout(close.current);
      close.current = setTimeout(() => {
        if (hold.current) return;
        shown.value = withTiming(0, { duration: 240 });
        close.current = setTimeout(() => {
          setOpen(false);
          opened.current?.(false);
        }, 260);
      }, after);
    },
    [shown],
  );
  useEffect(() => () => {
    if (close.current) clearTimeout(close.current);
  }, []);

  // A pinch shows the dial, and lets it go like a finger would.
  const wasTurning = useRef(false);
  useEffect(() => {
    if (turning) show();
    else if (wasTurning.current) hide();
    wasTurning.current = turning;
  }, [turning, show, hide]);

  const clamp = useCallback((z: number) => Math.min(max, Math.max(min, z)), [min, max]);

  // Dragging: the tick under the finger moves with it (the dial's rim rolls under it).
  const span = (R * DEG * Math.PI) / 180;
  const from = useRef(1);
  const last = useRef(1);
  const pegged = useRef(false);
  const turnTo = useCallback(
    (z: number) => {
      const prev = last.current;
      // A tick on every number passed, and one at either end.
      if (NUMBERS.some((n) => (prev < n && z >= n) || (prev > n && z <= n))) haptic.tick();
      const atEnd = z <= min + 1e-3 || z >= max - 1e-3;
      if (atEnd && !pegged.current) haptic.tap();
      pegged.current = atEnd;
      last.current = z;
      onZoom(z);
    },
    [min, max, onZoom],
  );
  const pan = Gesture.Pan()
    .runOnJS(true)
    .hitSlop({ horizontal: 16, vertical: 2 })
    .activeOffsetX([-6, 6])
    .onStart(() => {
      hold.current = true;
      from.current = value.value;
      last.current = value.value;
      show();
    })
    .onUpdate((e) => turnTo(zoomAfterDrag(from.current, e.translationX, span, min, max)))
    .onFinalize(() => {
      hold.current = false;
      hide();
    });

  // A tap goes to the next stop, gliding there like the Camera app's buttons.
  const glide = useRef<number | null>(null);
  const tapNext = useCallback(() => {
    const now = value.value;
    const target = nextZoomStop(now, min, max);
    if (glide.current) cancelAnimationFrame(glide.current);
    const start = Date.now();
    const step = () => {
      const k = Math.min(1, (Date.now() - start) / 220);
      const e = 1 - (1 - k) * (1 - k) * (1 - k);
      onZoom(now * Math.pow(target / now, e));
      glide.current = k < 1 ? requestAnimationFrame(step) : null;
    };
    haptic.tick();
    glide.current = requestAnimationFrame(step);
  }, [min, max, onZoom, value]);
  const tap = Gesture.Tap()
    .runOnJS(true)
    .hitSlop({ horizontal: 16, vertical: 2 })
    .onEnd((_e, ok) => {
      if (ok) tapNext();
    });

  // Scripted: rise, turn to `demo` over a second and a half, and stay up.
  useEffect(() => {
    if (demo === undefined || !Number.isFinite(demo)) return;
    hold.current = true;
    show();
    const begin = value.value;
    const target = clamp(demo);
    const start = Date.now();
    let raf = 0;
    const step = () => {
      const k = Math.min(1, (Date.now() - start) / 1500);
      const e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
      turnTo(begin * Math.pow(target / begin, e));
      if (k < 1) raf = requestAnimationFrame(step);
    };
    const t = setTimeout(() => (raf = requestAnimationFrame(step)), 400);
    return () => {
      clearTimeout(t);
      cancelAnimationFrame(raf);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [demo]);

  const dialStyle = useAnimatedStyle(() => ({
    opacity: shown.value,
    transform: [{ translateY: (1 - shown.value) * 18 }],
  }));
  const away = useSharedValue(0);
  useEffect(() => {
    away.value = withTiming(hidden ? 1 : 0, { duration: 140 });
  }, [hidden, away]);
  const buttonStyle = useAnimatedStyle(() => ({ opacity: (1 - shown.value) * (1 - away.value) }));
  // The ticks turn so the zoom now sits at the top, under the pointer.
  const turn = useAnimatedStyle(() => ({
    transform: [{ rotate: `${-DEG * Math.log(Math.max(0.01, value.value))}deg` }],
  }));

  // The band: between the circle and one BAND inside it, down to the chord.
  const cx = width / 2;
  const chord = TOP + H;
  const inner = R - BAND;
  const innerHalf = Math.sqrt(Math.max(0, inner * inner - (cy - chord) * (cy - chord)));
  const band = `M ${cx - width / 2} ${chord} A ${R} ${R} 0 0 1 ${cx + width / 2} ${chord} L ${cx + innerHalf} ${chord} A ${inner} ${inner} 0 0 0 ${cx - innerHalf} ${chord} Z`;
  const rim = `M ${cx - width / 2} ${chord} A ${R} ${R} 0 0 1 ${cx + width / 2} ${chord}`;

  return (
    <View style={styles.row} pointerEvents={hidden ? 'none' : 'box-none'}>
      {/* The finger stays on the button (it starts the drag); the dial only shows the turn. */}
      {open ? (
        <Animated.View style={[styles.dial, { width, height: chord, bottom: 22 }, dialStyle]} pointerEvents="none">
            <Svg width={width} height={chord} style={StyleSheet.absoluteFill} pointerEvents="none">
              <Path d={band} fill="#000000" fillOpacity={0.46} />
              <Path d={rim} fill="none" stroke="#FFFFFF" strokeOpacity={0.16} strokeWidth={1} />
            </Svg>
            <Animated.View style={[styles.wheel, { left: cx - R, top: TOP, width: 2 * R, height: 2 * R }, turn]} pointerEvents="none">
              <Svg width={2 * R} height={2 * R}>
                {ticks.map((t) => {
                  const a = (DEG * Math.log(t.z) * Math.PI) / 180;
                  const r0 = R - 6;
                  const r1 = r0 - (t.major ? 15 : 8);
                  return (
                    <Line
                      key={t.z}
                      x1={R + r0 * Math.sin(a)}
                      y1={R - r0 * Math.cos(a)}
                      x2={R + r1 * Math.sin(a)}
                      y2={R - r1 * Math.cos(a)}
                      stroke="#FFFFFF"
                      strokeOpacity={t.major ? 0.95 : 0.55}
                      strokeWidth={t.major ? 1.6 : 1}
                    />
                  );
                })}
                {ticks
                  .filter((t) => t.major)
                  .map((t) => (
                    <SvgText
                      key={`n${t.z}`}
                      x={R}
                      y={38}
                      transform={`rotate(${DEG * Math.log(t.z)} ${R} ${R})`}
                      textAnchor="middle"
                      fill="#FFFFFF"
                      fontSize={13}
                      fontWeight="600"
                      fontFamily={Platform.OS === 'web' ? 'Inter-SemiBold' : undefined}
                    >
                      {zoomText(t.z)}
                    </SvgText>
                  ))}
              </Svg>
            </Animated.View>
            {/* The pointer and the zoom it points at. */}
            <View style={[styles.pointer, { left: cx - 1.25, top: TOP - 3, backgroundColor: pen }]} />
            <Text style={[styles.readout, { color: pen, left: cx - 50, top: TOP - 30 }]}>{`${zoomText(zoom)}×`}</Text>
        </Animated.View>
      ) : null}
      <GestureDetector gesture={Gesture.Exclusive(pan, tap)}>
        <Animated.View
          style={[styles.button, buttonStyle]}
          accessible
          accessibilityRole="adjustable"
          accessibilityLabel="Zoom"
          accessibilityValue={{ text: `${zoomText(zoom)} times` }}
          accessibilityActions={[{ name: 'increment' }, { name: 'decrement' }]}
          onAccessibilityAction={(e) => onZoom(clamp(value.value * (e.nativeEvent.actionName === 'increment' ? 1.25 : 0.8)))}
        >
          <Text style={[styles.buttonText, { color: pen }]}>{`${zoomText(zoom)}×`}</Text>
        </Animated.View>
      </GestureDetector>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { height: 44, alignSelf: 'stretch', alignItems: 'center', justifyContent: 'center' },
  dial: { position: 'absolute', left: 0, overflow: 'hidden' },
  wheel: { position: 'absolute' },
  pointer: { position: 'absolute', width: 2.5, height: 17, borderRadius: 1.25 },
  readout: { position: 'absolute', width: 100, textAlign: 'center', ...face.semibold, fontSize: 15, fontVariant: ['tabular-nums'] },
  button: {
    minWidth: 42,
    height: 42,
    borderRadius: 21,
    paddingHorizontal: 6,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(11,11,12,0.55)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.18)',
  },
  buttonText: { ...face.semibold, fontSize: 13, fontVariant: ['tabular-nums'] },
});

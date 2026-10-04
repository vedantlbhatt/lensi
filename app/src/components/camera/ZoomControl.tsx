import { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { FadeIn, FadeOut, runOnJS, useAnimatedStyle, useSharedValue } from 'react-native-reanimated';

import { face } from '../../theme/type';
import { zoomText } from './ZoomChips';

const STOPS = [0.5, 1, 2, 5];
/** Ruler points per doubling of zoom. */
const OCTAVE = 92;
const WIDTH = 300;

/** Tick marks: every 0.1 below 2x, every 0.5 to 5x, then every 1. */
function ticks(min: number, max: number): number[] {
  const out: number[] = [];
  for (let z = 0.5; z <= 10.001; ) {
    if (z >= min - 0.001 && z <= max + 0.001) out.push(Math.round(z * 10) / 10);
    z += z < 2 ? 0.1 : z < 5 ? 0.5 : 1;
  }
  return out;
}

/**
 * Zoom the way the Camera app does: the stops (.5, 1, 2, 5) to tap; drag sideways on
 * them and they open into a thin ruler under a fixed mark, which closes again a moment
 * after the finger lifts. Logarithmic, so every doubling is the same distance.
 */
export function ZoomControl({
  zoom,
  min,
  max,
  pen,
  onZoom,
  peek,
}: {
  /** Changes: open the ruler for a moment (scripted recordings). */
  peek?: number;
  zoom: number;
  min: number;
  max: number;
  pen: string;
  onZoom: (z: number) => void;
}) {
  const [open, setOpen] = useState(false);
  const [shown, setShown] = useState(zoom);
  const lz = useSharedValue(Math.log2(zoom));
  const from = useSharedValue(0);
  const dragging = useRef(false);
  const closer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lo = Math.log2(min);
  const hi = Math.log2(max);

  // Follow pinches and taps made elsewhere.
  useEffect(() => {
    if (!dragging.current) {
      lz.value = Math.log2(zoom);
      setShown(zoom);
    }
  }, [zoom, lz]);
  useEffect(() => () => {
    if (closer.current) clearTimeout(closer.current);
  }, []);
  useEffect(() => {
    if (!peek) return;
    setOpen(true);
    if (closer.current) clearTimeout(closer.current);
    closer.current = setTimeout(() => setOpen(false), 2600);
  }, [peek]);

  const begin = () => {
    dragging.current = true;
    if (closer.current) clearTimeout(closer.current);
    setOpen(true);
  };
  const end = () => {
    dragging.current = false;
    if (closer.current) clearTimeout(closer.current);
    closer.current = setTimeout(() => setOpen(false), 1400);
  };
  const change = (v: number) => {
    const z = Math.pow(2, v);
    setShown(Math.round(z * 10) / 10);
    onZoom(z);
  };

  const pan = Gesture.Pan()
    .activeOffsetX([-6, 6])
    .failOffsetY([-14, 14])
    .onStart(() => {
      from.value = lz.value;
      runOnJS(begin)();
    })
    .onUpdate((e) => {
      const v = Math.min(hi, Math.max(lo, from.value - e.translationX / OCTAVE));
      if (Math.abs(v - lz.value) > 0.002) {
        lz.value = v;
        runOnJS(change)(v);
      }
    })
    .onFinalize(() => {
      runOnJS(end)();
    });

  const ruler = useAnimatedStyle(() => ({ transform: [{ translateX: WIDTH / 2 - (lz.value - lo) * OCTAVE }] }));

  const stops = STOPS.filter((s) => s >= min - 0.01 && s <= max + 0.01);
  const active = stops.reduce((a, s) => (zoom >= s - 0.05 ? s : a), stops[0]);

  return (
    <GestureDetector gesture={pan}>
      <View style={styles.slot} collapsable={false}>
        {open ? (
          <Animated.View key="ruler" entering={FadeIn.duration(140)} exiting={FadeOut.duration(220)} style={styles.rulerWrap}>
            <Text style={[styles.value, { color: pen }]}>{`${zoomText(shown)}×`}</Text>
            <View style={styles.window}>
              <Animated.View style={[styles.ruler, ruler]}>
                {ticks(min, max).map((z) => {
                  const major = STOPS.includes(z);
                  return (
                    <View key={z} style={[styles.tickAt, { left: (Math.log2(z) - lo) * OCTAVE }]}>
                      <View style={[styles.tick, major && styles.major]} />
                      {major ? <Text style={styles.tickText}>{zoomText(z)}</Text> : null}
                    </View>
                  );
                })}
              </Animated.View>
              <View style={[styles.mark, { backgroundColor: pen }]} />
            </View>
          </Animated.View>
        ) : (
          <Animated.View key="chips" entering={FadeIn.duration(180)} exiting={FadeOut.duration(100)} style={styles.row}>
            {stops.map((s) => {
              const on = s === active;
              return (
                <Pressable
                  key={s}
                  onPress={() => onZoom(s)}
                  hitSlop={6}
                  accessibilityRole="button"
                  accessibilityLabel={`Zoom ${zoomText(s)}x`}
                  accessibilityState={{ selected: on }}
                  style={[styles.chip, on && styles.on]}
                >
                  <Text style={[styles.text, on && { color: pen }]}>{on ? `${zoomText(zoom)}×` : zoomText(s)}</Text>
                </Pressable>
              );
            })}
          </Animated.View>
        )}
      </View>
    </GestureDetector>
  );
}

const styles = StyleSheet.create({
  slot: { height: 46, alignSelf: 'center', alignItems: 'center', justifyContent: 'center', minWidth: WIDTH },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    padding: 4,
    borderRadius: 22,
    backgroundColor: 'rgba(0,0,0,0.32)',
  },
  chip: { minWidth: 34, height: 34, borderRadius: 17, paddingHorizontal: 6, alignItems: 'center', justifyContent: 'center' },
  on: { minWidth: 42, backgroundColor: 'rgba(0,0,0,0.5)' },
  text: { color: '#FFFFFF', ...face.semibold, fontSize: 12, fontVariant: ['tabular-nums'] },
  rulerWrap: { alignItems: 'center' },
  value: { ...face.semibold, fontSize: 13, fontVariant: ['tabular-nums'], marginBottom: 2 },
  window: { width: WIDTH, height: 28, overflow: 'hidden' },
  ruler: { position: 'absolute', left: 0, top: 0, bottom: 0 },
  tickAt: { position: 'absolute', top: 0, alignItems: 'center', width: 20, marginLeft: -10 },
  tick: { width: 1, height: 7, backgroundColor: 'rgba(255,255,255,0.55)' },
  major: { height: 11, width: 1.5, backgroundColor: '#FFFFFF' },
  tickText: { color: '#FFFFFF', ...face.semibold, fontSize: 10, marginTop: 1, fontVariant: ['tabular-nums'] },
  mark: { position: 'absolute', left: WIDTH / 2 - 1, top: 0, width: 2, height: 14, borderRadius: 1 },
});

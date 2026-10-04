import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { cancelAnimation, Easing, FadeIn, FadeOut, useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';

import { haptic } from '../../lib/haptics';
import { STRIP_PAD as PAD, stripIndex, stripTick } from '../../lib/strip';
import { PressScale } from '../../motion/PressScale';
import { ShinyText } from '../../motion/ShinyText';
import { faint, ink, mist, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Icon } from '../icons/Icon';
import { Glass } from './Glass';

/** One thing the strip can pick: what the eyes call it, if anything. */
export type ScrubThing = { label: string | null };

/** Held still this long on a thing (ms), it's pinned. */
export const HOLD_MS = 1500;
/** A finger that drifts less than this (points) since the last change is holding still. */
const STILL = 10;
const HEIGHT = 50;

type Phase = 'idle' | 'finding' | 'choosing' | 'empty';

/**
 * Slide to pick, hold to pin. A finger on the strip asks the camera for the things in view,
 * fixed where they are the moment it lands (moving the phone doesn't change them); sliding
 * moves the highlight from one to the next, left to right; holding still on one for 1.5 s
 * pins it. Each change ticks; the pin lands with a firmer one. Letting go early pins nothing.
 */
export function ScrubStrip({
  pen,
  pins,
  onStart,
  onMove,
  onPin,
  onEnd,
  onClear,
  demo,
}: {
  pen: string;
  /** How many things are pinned now: a button to clear them shows when there are any. */
  pins: number;
  /** A finger landed: the things in view above `top` (where the strip is on screen), in order across it. */
  onStart: (top: number) => Promise<ScrubThing[]>;
  /** The highlighted thing changed. */
  onMove: (index: number) => void;
  /** Held still on it: pin it. */
  onPin: (index: number) => void;
  /** The finger left. */
  onEnd: () => void;
  onClear: () => void;
  /** Scripted runs (CI, the web demo): a finger lands at the first of these (0-1 across the strip), slides through the rest, holds on the last and lets go. */
  demo?: number[];
}) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [things, setThings] = useState<ScrubThing[]>([]);
  const [index, setIndex] = useState(-1);
  const [pinnedNow, setPinnedNow] = useState<number[]>([]);
  const [width, setWidth] = useState(0);
  const [tipWidth, setTipWidth] = useState(0);
  const widthRef = useRef(0);
  const touch = useRef<View>(null);
  // Everything the touch handlers need between renders.
  const s = useRef({ session: 0, down: false, x: 0, anchor: 0, index: -1, n: 0, pinned: new Set<number>() });
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const progress = useSharedValue(0);

  const indexAt = (x: number, n: number, current: number) => stripIndex(x, widthRef.current, n, current);

  const disarm = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
    cancelAnimation(progress);
  };

  // The hold starts over: from here, 1.5 s of stillness pins the highlighted thing.
  const arm = () => {
    disarm();
    const st = s.current;
    st.anchor = st.x;
    const i = st.index;
    if (i < 0 || st.pinned.has(i)) {
      progress.value = i >= 0 ? 1 : 0;
      return;
    }
    progress.value = 0;
    progress.value = withTiming(1, { duration: HOLD_MS, easing: Easing.linear });
    const session = st.session;
    timer.current = setTimeout(() => {
      timer.current = null;
      const now = s.current;
      if (now.session !== session || !now.down || now.index !== i) return;
      now.pinned.add(i);
      setPinnedNow([...now.pinned]);
      haptic.done();
      onPin(i);
    }, HOLD_MS);
  };

  const choose = (i: number) => {
    const st = s.current;
    if (i === st.index) return;
    st.index = i;
    setIndex(i);
    onMove(i);
    haptic.tick();
    arm();
  };

  const begin = (x: number) => {
    const st = s.current;
    if (st.down) return;
    st.session += 1;
    st.down = true;
    st.x = x;
    st.index = -1;
    st.n = 0;
    st.pinned = new Set();
    setPinnedNow([]);
    setIndex(-1);
    setThings([]);
    setPhase('finding');
    const session = st.session;
    const ask = (top: number) =>
      onStart(top)
        .then((list) => {
          const now = s.current;
          if (now.session !== session || !now.down) return;
          now.n = list.length;
          setThings(list);
          if (!list.length) {
            setPhase('empty');
            return;
          }
          setPhase('choosing');
          choose(indexAt(now.x, list.length, -1));
        })
        .catch(() => {
          if (s.current.session === session) setPhase('empty');
        });
    // Things are looked for above the strip: what's under the app's chrome can't be seen.
    if (touch.current) touch.current.measureInWindow((_x, y) => void ask(y));
    else void ask(NaN);
  };

  const move = (x: number) => {
    const st = s.current;
    st.x = x;
    if (st.n <= 0) return;
    const i = indexAt(x, st.n, st.index);
    if (i !== st.index) choose(i);
    else if (Math.abs(x - st.anchor) > STILL) arm();
  };

  const end = () => {
    const st = s.current;
    if (!st.down) return;
    st.down = false;
    st.session += 1;
    st.index = -1;
    st.n = 0;
    disarm();
    progress.value = withTiming(0, { duration: 160 });
    setPhase('idle');
    setIndex(-1);
    setThings([]);
    onEnd();
  };

  const gesture = Gesture.Pan()
    .runOnJS(true)
    .minDistance(0)
    .shouldCancelWhenOutside(false)
    .onBegin((e) => begin(e.x))
    .onUpdate((e) => move(e.x))
    .onFinalize(() => end());

  // Scripted: the same handlers a finger drives, once. Not again when the strip's width changes
  // (the unpin button beside it comes and goes): that started the finger over after every pin.
  const measured = width > 0;
  useEffect(() => {
    if (!demo?.length || !measured) return;
    const at = (f: number) => PAD + f * (widthRef.current - 2 * PAD);
    const steps: { t: number; run: () => void }[] = [{ t: 0, run: () => begin(at(demo[0])) }];
    let t = 900;
    demo.slice(1).forEach((f, j) => {
      // Slide there from the stop before, over a third of a second.
      const from = demo[j];
      for (let k = 1; k <= 8; k++) steps.push({ t: t + k * 40, run: () => move(at(from + ((f - from) * k) / 8)) });
      t += 700;
    });
    steps.push({ t: t + HOLD_MS + 900, run: end });
    const timers = steps.map((x) => setTimeout(x.run, 600 + x.t));
    return () => timers.forEach(clearTimeout);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [demo, measured]);

  useEffect(() => () => disarm(), []);

  const n = things.length;
  const tickX = (k: number) => stripTick(k, width, n);
  const thing = index >= 0 && index < n ? things[index] : null;
  const done = index >= 0 && pinnedNow.includes(index);
  const name = thing ? (thing.label ?? `Thing ${index + 1}`) : '';
  const tipLeft = thing ? Math.min(Math.max(0, tickX(index) - tipWidth / 2), Math.max(0, width - tipWidth)) : 0;
  const fill = useAnimatedStyle(() => ({ width: `${Math.round(progress.value * 1000) / 10}%` }));

  return (
    <View style={styles.wrap} pointerEvents="box-none">
      {thing ? (
        <View
          style={[styles.tip, { left: tipLeft, opacity: tipWidth ? 1 : 0 }]}
          onLayout={(e) => setTipWidth(Math.round(e.nativeEvent.layout.width))}
          pointerEvents="none"
        >
          <View style={styles.tipRow}>
            {done ? <Icon name="check" size={15} color={paper} stroke={2.4} /> : null}
            <Text style={styles.tipText} numberOfLines={1}>
              {done ? `Pinned · ${name}` : name}
            </Text>
            <Text style={styles.tipCount}>{`${index + 1} of ${n}`}</Text>
          </View>
          {/* The hold, filling in: ink on the pen colour, over the same words. */}
          <Animated.View style={[styles.tipFill, { backgroundColor: pen }, done ? styles.full : fill]}>
            <View style={[styles.tipRow, { width: tipWidth }]}>
              {done ? <Icon name="check" size={15} color={ink} stroke={2.4} /> : null}
              <Text style={[styles.tipText, { color: ink }]} numberOfLines={1}>
                {done ? `Pinned · ${name}` : name}
              </Text>
              <Text style={[styles.tipCount, { color: ink }]}>{`${index + 1} of ${n}`}</Text>
            </View>
          </Animated.View>
        </View>
      ) : null}
      <View style={styles.row} pointerEvents="box-none">
        <GestureDetector gesture={gesture}>
          <View
            ref={touch}
            style={styles.touch}
            onLayout={(e) => {
              widthRef.current = e.nativeEvent.layout.width;
              setWidth(e.nativeEvent.layout.width);
            }}
            accessible
            accessibilityRole="adjustable"
            accessibilityLabel="Pick a thing to pin"
            accessibilityHint="Slide along to move between the things in view, and hold still to pin one."
          >
            <Glass style={styles.bar}>
              {phase === 'choosing' ? (
                things.map((_, k) => {
                  const on = k === index;
                  const held = pinnedNow.includes(k);
                  return (
                    <View
                      key={k}
                      style={[
                        styles.tick,
                        { left: tickX(k) - (on ? 1.5 : 1), height: on ? 24 : 12, width: on ? 3 : 2, top: (HEIGHT - (on ? 24 : 12)) / 2 },
                        { backgroundColor: on || held ? pen : 'rgba(255,255,255,0.55)' },
                      ]}
                    />
                  );
                })
              ) : (
                <Animated.View key={phase} entering={FadeIn.duration(160)} exiting={FadeOut.duration(100)} style={styles.center} pointerEvents="none">
                  {phase === 'finding' ? (
                    <ShinyText text="Finding things" style={styles.say} />
                  ) : (
                    <Text style={[styles.say, phase === 'empty' && { color: faint }]}>
                      {phase === 'empty' ? 'Nothing to pin here' : 'Slide to pick · hold to pin'}
                    </Text>
                  )}
                </Animated.View>
              )}
            </Glass>
          </View>
        </GestureDetector>
        {pins > 0 && phase === 'idle' ? (
          <Animated.View entering={FadeIn.duration(180)} exiting={FadeOut.duration(120)}>
            <PressScale
              onPress={() => {
                haptic.thud();
                onClear();
              }}
              accessibilityRole="button"
              accessibilityLabel={pins === 1 ? 'Unpin it' : `Unpin all ${pins}`}
              hitSlop={6}
            >
              <Glass style={styles.clear}>
                <Icon name="close" size={18} color={mist} stroke={2.2} />
              </Glass>
            </PressScale>
          </Animated.View>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { alignSelf: 'stretch', marginHorizontal: 14 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  touch: { flex: 1, height: HEIGHT },
  bar: { flex: 1, borderRadius: HEIGHT / 2, borderCurve: 'continuous' },
  center: { position: 'absolute', left: 0, right: 0, top: 0, bottom: 0, alignItems: 'center', justifyContent: 'center' },
  say: { color: mist, ...face.semibold, fontSize: 14, letterSpacing: -0.1 },
  tick: { position: 'absolute', borderRadius: 1.5 },
  clear: { width: HEIGHT, height: HEIGHT, borderRadius: HEIGHT / 2, alignItems: 'center', justifyContent: 'center' },
  tip: {
    position: 'absolute',
    bottom: HEIGHT + 10,
    height: 34,
    borderRadius: 17,
    overflow: 'hidden',
    backgroundColor: 'rgba(11,11,12,0.78)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.16)',
  },
  tipRow: { height: 34, flexDirection: 'row', alignItems: 'center', gap: 7, paddingHorizontal: 14 },
  tipText: { color: paper, ...face.semibold, fontSize: 15, letterSpacing: -0.2, maxWidth: 220 },
  tipCount: { color: faint, ...face.medium, fontSize: 12.5, fontVariant: ['tabular-nums'] },
  tipFill: { position: 'absolute', left: 0, top: 0, bottom: 0, overflow: 'hidden' },
  full: { width: '100%' },
});

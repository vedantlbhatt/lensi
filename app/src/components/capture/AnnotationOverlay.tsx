import {
  BlurMask,
  Canvas,
  Circle,
  DashPathEffect,
  FillType,
  Group,
  Path,
  rect,
  rrect,
  Skia,
  Text as SkText,
  useFont,
  type SkFont,
  type SkPath,
} from '@shopify/react-native-skia';
import { useEffect, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import {
  Easing,
  useDerivedValue,
  useSharedValue,
  withDelay,
  withRepeat,
  withSequence,
  withSpring,
  withTiming,
  type EasingFunction,
  type EasingFunctionFactory,
  type SharedValue,
} from 'react-native-reanimated';

import { leaderPath, outlinePath, toView, type Fit } from '../../lib/geometry';
import type { Pt, Region, Step } from '../../lib/types';
import { springs } from '../../theme/motion';
import { alpha, ink } from '../../theme/tokens';
import { FRAME_RADIUS, type PlacedCallout } from './layout';

const MONO = require('@expo-google-fonts/fragment-mono/400Regular/FragmentMono_400Regular.ttf');

function svgPath(d: string): SkPath {
  return Skia.Path.MakeFromSVGString(d) ?? Skia.Path.Make();
}

/**
 * Everything drawn on top of the photo. The story it tells, in order: the
 * eyes outline the subject (light runs along the edge while the model
 * thinks), numbered marks appear on what the eyes found, and as the model
 * names things each label grows out of its mark.
 */
export function AnnotationOverlay({
  frame,
  subject,
  regions,
  placed,
  settled,
  thinking,
  walking,
  highlight,
  pen,
  focus,
}: {
  frame: Fit;
  subject: Region | null;
  regions: Region[];
  placed: PlacedCallout[];
  /** The photo has landed in its frame. */
  settled: boolean;
  thinking: boolean;
  walking: boolean;
  /** The part being shown right now: a walkthrough step, or a part an answer names. */
  highlight: Step | null;
  pen: string;
  /** Outline of a part the user just tapped, while its answer is on the way. */
  focus?: Pt[] | null;
}) {
  const font = useFont(MONO, 10);
  const clip = useMemo(() => rrect(rect(frame.x, frame.y, frame.w, frame.h), FRAME_RADIUS, FRAME_RADIUS), [frame]);
  const subjectD = useMemo(
    () => (subject?.polygon && subject.polygon.length > 2 ? outlinePath(subject.polygon, frame, 0.55) : null),
    [subject, frame],
  );
  const marks = useMemo(() => regions.filter((r) => r.kind !== 'subject').slice(0, 9), [regions]);
  const showMarks = settled && thinking && placed.length === 0;

  return (
    <View style={[StyleSheet.absoluteFill, styles.passthrough]}>
    <Canvas style={StyleSheet.absoluteFill}>
      <Group clip={clip}>
        {settled && subjectD ? <Spotlight d={subjectD} frame={frame} strong={walking} /> : null}
        {placed.map((c, i) =>
          c.polygon && c.polygon.length > 2 ? (
            <PartOutline key={`p-${c.id}`} d={outlinePath(c.polygon, frame, 0.5)} pen={pen} delay={120 + i * 90} dim={walking} />
          ) : null,
        )}
        {settled && subjectD ? <SubjectOutline d={subjectD} pen={pen} thinking={thinking} dim={walking} /> : null}
        {showMarks && font
          ? marks.map((r, i) => <Mark key={r.id} at={toView({ x: r.box.x + r.box.w / 2, y: r.box.y + r.box.h / 2 }, frame)} n={r.mark} pen={pen} font={font} delay={i * 70} />)
          : null}
        {highlight ? <StepHighlight key={highlight.id} step={highlight} frame={frame} pen={pen} /> : null}
        {focus && focus.length > 2 ? <Marching key={focus.length + focus[0].x} d={outlinePath(focus, frame, 0.5)} pen={pen} /> : null}
      </Group>
      {placed.map((c, i) => (
        <Leader key={`l-${c.id}`} from={c.slot.anchor} to={c.slot.attach} delay={i * 110} dim={walking} />
      ))}
      {placed.map((c, i) => (
        <Dot key={`d-${c.id}`} at={c.slot.anchor} pen={pen} delay={i * 110} dim={walking} />
      ))}
    </Canvas>
    </View>
  );
}

const styles = StyleSheet.create({ passthrough: { pointerEvents: 'none' } });

const DRAW = Easing.bezier(0.16, 1, 0.3, 1);
// Made once: an easing built during render is a new function every time, which
// re-runs the effect that starts the animation.
const LEADER = Easing.out(Easing.cubic);

function useEnter(delay: number, duration = 900, easing: EasingFunction | EasingFunctionFactory = DRAW) {
  const t = useSharedValue(0);
  useEffect(() => {
    t.value = withDelay(delay, withTiming(1, { duration, easing }));
  }, [delay, duration, easing, t]);
  return t;
}

function useDim(dim: boolean, low = 0.25) {
  const d = useSharedValue(1);
  useEffect(() => {
    d.value = withTiming(dim ? low : 1, { duration: 320 });
  }, [dim, low, d]);
  return d;
}

/** Darkens everything but the subject. Even-odd fill punches the hole. */
function Spotlight({ d, frame, strong }: { d: string; frame: Fit; strong: boolean }) {
  const path = useMemo(() => {
    const p = svgPath(d);
    p.addRect(rect(frame.x - 2, frame.y - 2, frame.w + 4, frame.h + 4));
    p.setFillType(FillType.EvenOdd);
    return p;
  }, [d, frame]);
  const t = useEnter(650, 700);
  const k = useSharedValue(0.3);
  useEffect(() => {
    k.value = withTiming(strong ? 0.58 : 0.3, { duration: 420 });
  }, [strong, k]);
  const opacity = useDerivedValue(() => t.value * k.value);
  return <Path path={path} color="#000" opacity={opacity} />;
}

function SubjectOutline({ d, pen, thinking, dim }: { d: string; pen: string; thinking: boolean; dim: boolean }) {
  const path = useMemo(() => svgPath(d), [d]);
  const draw = useEnter(80, 1100);
  // A short bright run of light circling the outline while the model thinks.
  const run = useSharedValue(0);
  const runOpacity = useSharedValue(0);
  useEffect(() => {
    if (thinking) {
      runOpacity.value = withDelay(900, withTiming(1, { duration: 300 }));
      run.value = withDelay(900, withRepeat(withTiming(1, { duration: 1700, easing: Easing.inOut(Easing.quad) }), -1, true));
    } else {
      runOpacity.value = withTiming(0, { duration: 400 });
    }
  }, [thinking, run, runOpacity]);
  const runStart = useDerivedValue(() => run.value * 0.84);
  const runEnd = useDerivedValue(() => run.value * 0.84 + 0.16);
  const dimmer = useDim(dim, 0.45);
  const glowOpacity = useDerivedValue(() => 0.75 * dimmer.value);
  return (
    <Group opacity={dimmer}>
      <Path path={path} style="stroke" strokeWidth={7} color={alpha(pen, 0.55)} end={draw} strokeJoin="round" strokeCap="round" opacity={glowOpacity}>
        <BlurMask blur={7} style="normal" />
      </Path>
      <Path path={path} style="stroke" strokeWidth={2.6} color={pen} end={draw} strokeJoin="round" strokeCap="round" />
      <Path path={path} style="stroke" strokeWidth={3.4} color="#FFFFFF" start={runStart} end={runEnd} strokeJoin="round" strokeCap="round" opacity={runOpacity}>
        <BlurMask blur={2} style="solid" />
      </Path>
    </Group>
  );
}

function PartOutline({ d, pen, delay, dim }: { d: string; pen: string; delay: number; dim: boolean }) {
  const path = useMemo(() => svgPath(d), [d]);
  const draw = useEnter(delay, 700);
  const dimmer = useDim(dim, 0.15);
  const fillOpacity = useDerivedValue(() => draw.value * dimmer.value);
  return (
    <Group>
      <Path path={path} color={alpha(pen, 0.16)} opacity={fillOpacity} />
      <Path path={path} style="stroke" strokeWidth={1.5} color="rgba(255,255,255,0.92)" end={draw} strokeJoin="round" opacity={dimmer} />
    </Group>
  );
}

/** A numbered set-of-marks tag: what the eyes found, before the model names it. */
function Mark({ at, n, pen, font, delay }: { at: Pt; n: number; pen: string; font: SkFont; delay: number }) {
  const s = useSharedValue(0);
  useEffect(() => {
    s.value = withDelay(delay, withSpring(1, springs.pop));
  }, [delay, s]);
  const transform = useDerivedValue(() => [{ scale: s.value }]);
  const label = String(n);
  // Fragment Mono advances exactly 0.618 em (measureText isn't on web).
  const w = label.length * font.getSize() * 0.618;
  return (
    <Group transform={transform} origin={at}>
      <Circle cx={at.x} cy={at.y} r={9.5} color="rgba(11,11,12,0.55)" />
      <Circle cx={at.x} cy={at.y} r={8} color={pen} />
      <SkText x={at.x - w / 2} y={at.y + 3.6} text={label} font={font} color={ink} />
    </Group>
  );
}

function Leader({ from, to, delay, dim }: { from: Pt; to: Pt; delay: number; dim: boolean }) {
  const path = useMemo(() => svgPath(leaderPath(from, to)), [from, to]);
  const draw = useEnter(delay + 140, 420, LEADER);
  const dimmer = useDim(dim, 0.12);
  return (
    <Group opacity={dimmer}>
      <Path path={path} style="stroke" strokeWidth={3.2} color="rgba(0,0,0,0.28)" end={draw} strokeCap="round" />
      <Path path={path} style="stroke" strokeWidth={1.4} color="rgba(255,255,255,0.95)" end={draw} strokeCap="round" />
    </Group>
  );
}

function Dot({ at, pen, delay, dim }: { at: Pt; pen: string; delay: number; dim: boolean }) {
  const s = useSharedValue(0);
  const ring = useSharedValue(0);
  useEffect(() => {
    s.value = withDelay(delay, withSpring(1, springs.pop));
    ring.value = withDelay(delay, withSequence(withTiming(0, { duration: 1 }), withTiming(1, { duration: 700, easing: Easing.out(Easing.cubic) })));
  }, [delay, s, ring]);
  const transform = useDerivedValue(() => [{ scale: s.value }]);
  const ringR = useDerivedValue(() => 5 + ring.value * 15);
  const ringOpacity = useDerivedValue(() => (1 - ring.value) * 0.9);
  const dimmer = useDim(dim, 0.2);
  return (
    <Group opacity={dimmer}>
      <Circle cx={at.x} cy={at.y} r={ringR} style="stroke" strokeWidth={1.5} color={pen} opacity={ringOpacity} />
      <Group transform={transform} origin={at}>
        <Circle cx={at.x} cy={at.y} r={6.6} color="rgba(0,0,0,0.35)" />
        <Circle cx={at.x} cy={at.y} r={5.4} color="#FFFFFF" />
        <Circle cx={at.x} cy={at.y} r={3.6} color={pen} />
      </Group>
    </Group>
  );
}

/** Marching ants around a tapped part: "this one", while the model answers. */
function Marching({ d, pen }: { d: string; pen: string }) {
  const path = useMemo(() => svgPath(d), [d]);
  const draw = useEnter(0, 520);
  const phase = useSharedValue(0);
  useEffect(() => {
    phase.value = withRepeat(withTiming(-22, { duration: 900, easing: Easing.linear }), -1, false);
  }, [phase]);
  const fill = useDerivedValue(() => draw.value * 0.9);
  return (
    <Group>
      <Path path={path} color={alpha(pen, 0.14)} opacity={fill} />
      <Path path={path} style="stroke" strokeWidth={2.4} color="rgba(0,0,0,0.45)" end={draw} strokeJoin="round" />
      <Path path={path} style="stroke" strokeWidth={2} color={pen} end={draw} strokeJoin="round" strokeCap="round">
        <DashPathEffect intervals={[7, 4]} phase={phase} />
      </Path>
    </Group>
  );
}

/** The current walkthrough target: its outline glows; a bare point gets rings. */
function StepHighlight({ step, frame, pen }: { step: Step; frame: Fit; pen: string }) {
  const d = useMemo(() => (step.polygon && step.polygon.length > 2 ? outlinePath(step.polygon, frame, 0.5) : null), [step, frame]);
  const path = useMemo(() => (d ? svgPath(d) : null), [d]);
  const t = useEnter(260, 650);
  const pulse = useSharedValue(0);
  useEffect(() => {
    pulse.value = withRepeat(withTiming(1, { duration: 1300, easing: Easing.inOut(Easing.sin) }), -1, true);
  }, [pulse]);
  const glow = useDerivedValue(() => (0.35 + pulse.value * 0.45) * t.value);
  const at = step.at ? toView(step.at, frame) : null;
  const r1 = useDerivedValue(() => 18 + pulse.value * 5);
  const r2 = useDerivedValue(() => 30 + pulse.value * 9);
  const o2 = useDerivedValue(() => (0.55 - pulse.value * 0.35) * t.value);
  if (path) {
    return (
      <Group>
        <Path path={path} color={alpha(pen, 0.22)} opacity={t} />
        <Path path={path} style="stroke" strokeWidth={8} color={pen} opacity={glow}>
          <BlurMask blur={8} style="normal" />
        </Path>
        <Path path={path} style="stroke" strokeWidth={2.8} color={pen} end={t} strokeJoin="round" />
      </Group>
    );
  }
  if (!at) return null;
  return (
    <Group>
      <Circle cx={at.x} cy={at.y} r={r2} style="stroke" strokeWidth={2} color={pen} opacity={o2} />
      <Circle cx={at.x} cy={at.y} r={r1} style="stroke" strokeWidth={3} color={pen} opacity={t} />
      <Circle cx={at.x} cy={at.y} r={r1} color={alpha(pen, 0.18)} opacity={t} />
    </Group>
  );
}

export type { SharedValue };

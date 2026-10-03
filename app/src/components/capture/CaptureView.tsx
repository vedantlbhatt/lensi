import { Image } from 'expo-image';
import * as Speech from 'expo-speech';
import { useVideoPlayer, VideoView } from 'expo-video';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  Easing,
  FadeIn,
  interpolate,
  useAnimatedKeyboard,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
  withTiming,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { scheduleOnRN } from 'react-native-worklets';

import { devhooks } from '../../lib/devhooks';
import { fromView, toView } from '../../lib/geometry';
import { haptic } from '../../lib/haptics';
import { say } from '../../lib/narrate';
import { analyze, ask, askAbout, cancel, isHowTo, switchMoment } from '../../lib/pipeline';
import { setSettings, useSettings } from '../../lib/settings';
import { getCapture, removeCapture, useCapture } from '../../lib/store';
import type { Capture, Pt } from '../../lib/types';
import { Sparks, type SparksRef } from '../../motion/Sparks';
import { PressScale } from '../../motion/PressScale';
import { ShinyText } from '../../motion/ShinyText';
import { springs } from '../../theme/motion';
import { glassStrong, hairline, ink, lensInfo, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Glass } from '../camera/Glass';
import { Icon } from '../icons/Icon';
import { toast } from '../ui/Toast';
import { AnnotationOverlay } from './AnnotationOverlay';
import { AskBar } from './AskBar';
import { CalloutLabels } from './CalloutLabels';
import { InfoCard } from './InfoCard';
import { MomentStrip } from './MomentStrip';
import { activeSteps, CARD_PEEK, FRAME_RADIUS, placeCallouts, stageFor } from './layout';
import { renderAnnotated, shareCapture } from './share';
import { StepPlayer } from './StepPlayer';
import { WalkPointer } from './WalkPointer';

export type Rect = { x: number; y: number; w: number; h: number };

/**
 * A capture, annotated. Opens from the camera as a full-bleed still that
 * springs back into a framed print (the crop opening up to the whole photo),
 * then the eyes and the model draw on it. Swipe down to file it into
 * Memories.
 */
export function CaptureView({
  id,
  origin,
  dismissTo,
  onClosed,
}: {
  id: string;
  /** 'camera' = continue from the full-bleed preview; a rect = grow from a Memories tile. */
  origin: 'camera' | Rect;
  dismissTo: Rect;
  onClosed: () => void;
}) {
  const capture = useCapture(id);
  if (!capture) return null;
  return <Inner capture={capture} origin={origin} dismissTo={dismissTo} onClosed={onClosed} />;
}

function Inner({ capture, origin, dismissTo, onClosed }: { capture: Capture; origin: 'camera' | Rect; dismissTo: Rect; onClosed: () => void }) {
  const screen = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const settings = useSettings();
  const lens = lensInfo(capture.lens);
  const stage = useMemo(
    () => stageFor(capture.media, screen, { top: insets.top, bottom: insets.bottom }),
    [capture.media, screen, insets.top, insets.bottom],
  );
  const { frame } = stage;

  // ---- open / close choreography -------------------------------------------------
  const p = useSharedValue(0);
  const drag = useSharedValue(0);
  const closing = useSharedValue(0);
  const [settled, setSettled] = useState(false);
  const start: Rect = origin === 'camera' ? { x: stage.bleed.x, y: stage.bleed.y, w: stage.bleed.w, h: stage.bleed.h } : origin;

  useEffect(() => {
    p.value = withSpring(1, origin === 'camera' ? { damping: 22, stiffness: 170, mass: 1 } : springs.arrive);
    const t = setTimeout(() => setSettled(true), origin === 'camera' ? 520 : 380);
    return () => clearTimeout(t);
  }, [p, origin]);

  const close = useCallback(() => {
    Speech.stop().catch(() => {});
    closing.value = withTiming(1, { duration: 420, easing: Easing.bezier(0.5, 0, 0.2, 1) }, (done) => {
      if (done) scheduleOnRN(onClosed);
    });
  }, [closing, onClosed]);

  const frameStyle = useAnimatedStyle(() => {
    // Interpolate the photo rect: start → frame, then frame → memories button.
    const q = p.value;
    const c = closing.value;
    let x = start.x + (frame.x - start.x) * q;
    let y = start.y + (frame.y - start.y) * q + drag.value;
    let w = start.w + (frame.w - start.w) * q;
    let h = start.h + (frame.h - start.h) * q;
    const dragScale = 1 - Math.min(0.25, Math.max(0, drag.value) / 1400);
    w *= dragScale;
    h *= dragScale;
    x += (frame.w - w) / 2;
    if (c > 0) {
      // Fit the print into the memories button, keeping its aspect.
      const s = Math.max(dismissTo.w / w, dismissTo.h / h);
      x = x + (dismissTo.x + dismissTo.w / 2 - (x + (w * s) / 2)) * c;
      y = y + (dismissTo.y + dismissTo.h / 2 - (y + (h * s) / 2)) * c;
      w = w + (w * s - w) * c;
      h = h + (h * s - h) * c;
    }
    const sx = w / frame.w;
    const sy = h / frame.h;
    return {
      transform: [
        { translateX: x + w / 2 - (frame.x + frame.w / 2) },
        { translateY: y + h / 2 - (frame.y + frame.h / 2) },
        { scaleX: sx },
        { scaleY: sy },
      ],
      borderRadius: interpolate(q, [0, 1], [0, FRAME_RADIUS]) / Math.max(0.2, Math.min(sx, sy)) + c * 6,
      opacity: 1 - c * 0.15,
    };
  });
  const chrome = useAnimatedStyle(() => ({
    opacity: interpolate(p.value, [0.5, 1], [0, 1], 'clamp') * (1 - closing.value) * (1 - Math.min(1, Math.max(0, drag.value) / 220)),
  }));
  const backdrop = useAnimatedStyle(() => ({
    opacity: (origin === 'camera' ? 1 : p.value) * (1 - closing.value) * (1 - Math.min(0.6, Math.max(0, drag.value) / 500)),
  }));

  const dismiss = Gesture.Pan()
    .activeOffsetY([12, 999])
    .failOffsetX([-30, 30])
    .onUpdate((e) => {
      drag.value = Math.max(0, e.translationY);
    })
    .onEnd((e) => {
      if (e.translationY > 140 || e.velocityY > 900) {
        scheduleOnRN(close);
      } else {
        drag.value = withSpring(0, springs.arrive);
      }
    });

  // ---- annotations ---------------------------------------------------------------
  const placed = useMemo(() => (settled ? placeCallouts(capture.annotation.callouts, stage) : []), [capture.annotation.callouts, stage, settled]);
  const { steps, key: stepsKey, pending: stepsPending } = activeSteps(capture);
  const [walking, setWalking] = useState(false);
  const [stepIndex, setStepIndex] = useState(0);
  const autoWalked = useRef<string | null>(null);

  // A walkthrough that was asked for starts itself as soon as step one lands.
  useEffect(() => {
    if (!steps.length || autoWalked.current === stepsKey) return;
    autoWalked.current = stepsKey;
    setStepIndex(0);
    setWalking(true);
  }, [steps.length, stepsKey]);

  const step = walking ? (steps[Math.min(stepIndex, steps.length - 1)] ?? null) : null;
  useEffect(() => {
    if (!walking || !step || !settings.narrate) return;
    void say(step.text);
  }, [walking, step, settings.narrate]);
  useEffect(() => () => void Speech.stop().catch(() => {}), []);

  const pointerTarget = step?.at ? toView(step.at, frame) : null;

  // CI: render the share image once the annotation has landed.
  const exported = useRef(false);
  useEffect(() => {
    if (!devhooks.autoExport || exported.current || !settled || capture.status !== 'ready') return;
    exported.current = true;
    const t = setTimeout(() => {
      renderAnnotated(capture, placed, stage)
        .then((uri) => console.log(`[lensi] exported ${uri}`))
        .catch((e) => console.warn('[lensi] export failed', e));
    }, 1500);
    return () => clearTimeout(t);
  }, [settled, capture, placed, stage]);
  const thinking = capture.status === 'analyzing';
  const anyPending = thinking || capture.thread.some((x) => x.pending);

  // ---- card ------------------------------------------------------------------------
  const [expanded, setExpanded] = useState(false);

  // ---- tap the print: "what's this?" ------------------------------------------------
  const sparks = useRef<SparksRef>(null);
  const [focus, setFocus] = useState<Pt[] | null>(null);
  const focusAsked = useRef<number>(0);
  const tapPrint = Gesture.Tap()
    .maxDuration(250)
    .runOnJS(true)
    .onEnd((e, ok) => {
      if (!ok || !settled) return;
      const at = fromView({ x: frame.x + e.x, y: frame.y + e.y }, frame);
      if (at.x < 0 || at.y < 0 || at.x > 1 || at.y > 1) return;
      sparks.current?.burst(frame.x + e.x, frame.y + e.y, lens.pen);
      haptic.tap();
      setFocus(null);
      setExpanded(false);
      focusAsked.current = capture.thread.length;
      void askAbout(capture.id, at).then(setFocus);
    });
  // Let the marching ants go once the answer to that tap has landed.
  useEffect(() => {
    if (!focus) return;
    const ex = capture.thread[focusAsked.current];
    if (ex && !ex.pending) {
      const t = setTimeout(() => setFocus(null), 1600);
      return () => clearTimeout(t);
    }
  }, [focus, capture.thread]);

  const keyboard = useAnimatedKeyboard();
  const cardStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: -Math.max(0, keyboard.height.value - insets.bottom) }],
  }));
  const cardDrag = Gesture.Pan()
    .activeOffsetY([-10, 10])
    .runOnJS(true)
    .onEnd((e) => {
      if (e.translationY < -30 || e.velocityY < -500) setExpanded(true);
      else if (e.translationY > 30 || e.velocityY > 500) setExpanded(false);
    });

  // Answers to spoken questions are spoken back, heyclicky style.
  const spoken = useRef(new Set<string>());
  const said = useRef(new Set<string>());
  useEffect(() => {
    if (capture.source === 'voice' && capture.thread[0]) spoken.current.add(capture.thread[0].id);
  }, [capture.source, capture.thread]);
  useEffect(() => {
    if (!settings.narrate) return;
    for (const x of capture.thread) {
      if (!spoken.current.has(x.id) || said.current.has(x.id) || x.pending || !x.answer.length) continue;
      said.current.add(x.id);
      void say(x.answer.join(' '));
    }
  }, [capture.thread, settings.narrate]);

  const onAsk = (q: string, byVoice = false) => {
    const before = new Set(capture.thread.map((x) => x.id));
    void ask(capture.id, q);
    if (byVoice) {
      // The exchange id is created synchronously inside ask(); find it next tick.
      setTimeout(() => {
        const fresh = getCapture(capture.id)?.thread.find((x) => !before.has(x.id));
        if (fresh) spoken.current.add(fresh.id);
      }, 0);
    }
    if (isHowTo(q)) toast('Building a walkthrough…');
  };

  const engineLabel = capture.engine === 'apple' ? 'ON-DEVICE' : capture.engine === 'cloud' ? 'CLAUDE' : capture.engine === 'vision' ? 'EYES ONLY' : '';

  return (
    <View style={StyleSheet.absoluteFill}>
      <Animated.View style={[StyleSheet.absoluteFill, styles.backdrop, backdrop]} />

      {/* The print */}
      <GestureDetector gesture={Gesture.Race(dismiss, tapPrint)}>
        <Animated.View
          style={[styles.print, { left: frame.x, top: frame.y, width: frame.w, height: frame.h }, frameStyle]}
          accessibilityLabel={capture.annotation.title ?? 'Capture'}
        >
          <Media capture={capture} annotating={settled} />
        </Animated.View>
      </GestureDetector>

      {/* Drawing + labels + pointer (screen space, after the print settles) */}
      <Animated.View style={[StyleSheet.absoluteFill, chrome]} pointerEvents="box-none">
        <AnnotationOverlay
          frame={frame}
          subject={capture.subject}
          regions={capture.regions}
          placed={placed}
          settled={settled}
          thinking={thinking}
          walking={walking}
          step={step}
          pen={lens.pen}
          focus={walking ? null : focus}
        />
        <CalloutLabels placed={placed} pen={lens.pen} dim={walking} onPress={(c) => onAsk(`Tell me about the ${c.label.toLowerCase()}`)} />
        {walking ? <WalkPointer target={pointerTarget} index={stepIndex} pen={lens.pen} home={{ x: screen.width / 2, y: screen.height - CARD_PEEK }} /> : null}
      </Animated.View>

      {capture.media.kind === 'video' && capture.moments.length > 1 && settled && !walking ? (
        <Animated.View style={[styles.moments, { left: frame.x + 10, top: frame.y + frame.h - 66 }, chrome]}>
          <MomentStrip moments={capture.moments} active={capture.media.stillUri} pen={lens.pen} onPick={(uri) => switchMoment(capture.id, uri)} />
        </Animated.View>
      ) : null}

      <Sparks ref={sparks} color={lens.pen} />

      {/* Top bar */}
      <Animated.View style={[styles.top, { top: insets.top + 6 }, chrome]} pointerEvents="box-none">
        <PressScale onPress={close} accessibilityRole="button" accessibilityLabel="Close" scaleTo={0.85} hitSlop={8}>
          <Glass style={styles.round}>
            <Icon name="close" size={20} />
          </Glass>
        </PressScale>
        <View style={styles.engine}>
          {anyPending ? (
            <ShinyText text={capture.engine ? `${engineLabel} · THINKING` : 'LOOKING'} style={styles.engineText} />
          ) : engineLabel ? (
            <Animated.View entering={FadeIn} style={styles.engineRow}>
              {capture.engine === 'apple' ? <Icon name="spark" size={12} color={lens.pen} fill={lens.pen} stroke={1} /> : null}
              <Text style={styles.engineText}>{engineLabel}</Text>
            </Animated.View>
          ) : null}
        </View>
        <View style={styles.topRight}>
          <PressScale
            onPress={() => {
              removeCapture(capture.id);
              cancel(capture.id);
              onClosed();
            }}
            accessibilityRole="button"
            accessibilityLabel="Delete"
            scaleTo={0.85}
            hitSlop={8}
          >
            <Glass style={styles.round}>
              <Icon name="trash" size={19} />
            </Glass>
          </PressScale>
          <PressScale onPress={() => void shareCapture(capture, placed, stage)} accessibilityRole="button" accessibilityLabel="Share" scaleTo={0.85} hitSlop={8}>
            <Glass style={styles.round}>
              <Icon name="share" size={19} />
            </Glass>
          </PressScale>
        </View>
      </Animated.View>

      {/* Bottom card */}
      <Animated.View style={[styles.cardWrap, { paddingBottom: insets.bottom + 8 }, chrome, cardStyle]} pointerEvents="box-none">
        <GestureDetector gesture={cardDrag}>
          <View style={styles.card}>
            <View style={styles.handle} />
            {walking && steps.length ? (
              <StepPlayer
                steps={steps}
                question={stepsKey === 'capture' ? capture.prompt : capture.thread.find((x) => x.id === stepsKey)?.question}
                index={Math.min(stepIndex, steps.length - 1)}
                pending={stepsPending}
                pen={lens.pen}
                narrate={settings.narrate}
                onIndex={(i) => {
                  haptic.thud();
                  setStepIndex(i);
                }}
                onNarrate={() => {
                  if (settings.narrate) Speech.stop().catch(() => {});
                  setSettings({ narrate: !settings.narrate });
                }}
                onExit={() => {
                  Speech.stop().catch(() => {});
                  if (stepIndex >= steps.length - 1) haptic.done();
                  setWalking(false);
                }}
              />
            ) : (
              <InfoCard
                capture={capture}
                expanded={expanded}
                canWalk={steps.length > 0}
                onWalk={() => {
                  setStepIndex(0);
                  setWalking(true);
                }}
                onRetry={() => void analyze(capture.id, { walkthrough: capture.lens === 'guide' })}
                onSuggest={onAsk}
              />
            )}
            {!walking ? (
              <View style={styles.ask}>
                <AskBar pen={lens.pen} busy={false} onAsk={onAsk} onFocus={() => setExpanded(true)} />
              </View>
            ) : null}
          </View>
        </GestureDetector>
      </Animated.View>
    </View>
  );
}

function Media({ capture, annotating }: { capture: Capture; annotating: boolean }) {
  if (capture.media.kind === 'video') return <VideoMedia capture={capture} annotating={annotating} />;
  return <Image source={{ uri: capture.media.stillUri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={0} />;
}

/**
 * Video plays once through, then freezes on the analysed moment so the
 * drawing lines up with the picture. Tap to play again.
 */
function VideoMedia({ capture, annotating }: { capture: Capture; annotating: boolean }) {
  const player = useVideoPlayer(capture.media.uri, (pl) => {
    pl.loop = false;
    pl.muted = true;
    pl.play();
  });
  const [playing, setPlaying] = useState(true);
  useEffect(() => {
    const sub = player.addListener('playToEnd', () => setPlaying(false));
    const t = setTimeout(() => {
      player.pause();
      setPlaying(false);
    }, 2400);
    return () => {
      sub.remove();
      clearTimeout(t);
    };
  }, [player]);
  const stillOpacity = useSharedValue(0);
  useEffect(() => {
    stillOpacity.value = withTiming(annotating && !playing ? 1 : 0, { duration: 260 });
  }, [annotating, playing, stillOpacity]);
  const still = useAnimatedStyle(() => ({ opacity: stillOpacity.value }));
  return (
    <View style={StyleSheet.absoluteFill}>
      <VideoView player={player} style={StyleSheet.absoluteFill} contentFit="cover" nativeControls={false} />
      <Animated.View style={[StyleSheet.absoluteFill, still]} pointerEvents="none">
        <Image source={{ uri: capture.media.stillUri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={0} />
      </Animated.View>
      <View style={styles.videoBadge} pointerEvents="box-none">
        <PressScale
          onPress={() => {
            if (playing) {
              player.pause();
              setPlaying(false);
            } else {
              player.currentTime = 0;
              player.play();
              setPlaying(true);
            }
          }}
          accessibilityRole="button"
          accessibilityLabel={playing ? 'Pause video' : 'Play video'}
          scaleTo={0.85}
        >
          <View style={styles.playBtn}>
            <Icon name={playing ? 'pause' : 'play'} size={16} color={ink} />
          </View>
        </PressScale>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  backdrop: { backgroundColor: ink },
  print: { position: 'absolute', overflow: 'hidden', backgroundColor: '#000', borderCurve: 'continuous' },
  top: { position: 'absolute', left: 14, right: 14, height: 44, flexDirection: 'row', alignItems: 'center' },
  topRight: { flexDirection: 'row', gap: 10 },
  round: { width: 42, height: 42, borderRadius: 21, alignItems: 'center', justifyContent: 'center' },
  engine: { flex: 1, alignItems: 'center' },
  engineRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  engineText: { color: paper, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.3 },
  cardWrap: { position: 'absolute', left: 10, right: 10, bottom: 0 },
  card: {
    borderRadius: 30,
    borderCurve: 'continuous',
    backgroundColor: glassStrong,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    paddingHorizontal: 18,
    paddingTop: 10,
    paddingBottom: 12,
    minHeight: CARD_PEEK - 12,
  },
  handle: { alignSelf: 'center', width: 36, height: 4, borderRadius: 2, backgroundColor: 'rgba(244,241,234,0.22)', marginBottom: 10 },
  ask: { marginTop: 14 },
  videoBadge: { position: 'absolute', right: 12, bottom: 12 },
  moments: { position: 'absolute' },
  playBtn: { width: 36, height: 36, borderRadius: 18, backgroundColor: paper, alignItems: 'center', justifyContent: 'center' },
});

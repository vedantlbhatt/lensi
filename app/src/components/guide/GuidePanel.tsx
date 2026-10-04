import { useState } from 'react';
import { ScrollView, StyleSheet, Text, TextInput, useWindowDimensions, View } from 'react-native';
import Animated, { FadeIn, FadeInDown, FadeOut, useAnimatedStyle, type SharedValue } from 'react-native-reanimated';

import type { GuidePart, GuideState, GuideStep } from '../../lib/guide';
import { PressScale } from '../../motion/PressScale';
import { ShinyText } from '../../motion/ShinyText';
import { faint, glassStrong, hairline, ink, mist, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Icon } from '../icons/Icon';

/** Things people actually do with their hands full, as one-tap starts. */
const STARTERS = ['Leaking pipe under the sink', 'Check the tyre pressure', 'Reset a tripped breaker', 'Replace the air filter'];

/**
 * The directions panel for the live guide. Idle: say (or type, or pick) what
 * you're working on. Then one step at a time, with what the app is watching
 * and what it saw, and big targets for wet or greasy hands.
 */
export function GuidePanel({
  state,
  step,
  part,
  watching,
  pen,
  listening,
  handsFree,
  transcript,
  level,
  onMic,
  onSubmit,
  onNext,
  onBack,
  onCheck,
  onRepeat,
  onStop,
}: {
  state: GuideState;
  step: GuideStep | null;
  part: GuidePart | null;
  watching: boolean;
  pen: string;
  listening: boolean;
  /** The mic keeps opening by itself between the app's lines. */
  handsFree: boolean;
  transcript: string;
  level: SharedValue<number>;
  onMic: () => void;
  onSubmit: (text: string) => void;
  onNext: () => void;
  onBack: () => void;
  onCheck: () => void;
  onRepeat: () => void;
  onStop: () => void;
}) {
  const [typed, setTyped] = useState('');
  // Narrow phones (under 390 pt): Check drops its word, so Next keeps room for its own.
  const compact = useWindowDimensions().width < 390;
  const submit = () => {
    const t = typed.trim();
    if (!t) return;
    setTyped('');
    onSubmit(t);
  };
  const idle = state.status === 'idle';
  const working = state.status === 'planning';
  // The last step there is, not just the last to have arrived while the plan streams in.
  const lastStep = state.index >= state.steps.length - 1 && !state.streaming;
  const finished = state.status === 'finished';
  const busy = state.status === 'checking' || state.status === 'answering';
  // Tapped to talk: the panel is all ears. Hands free, the step stays put and what's heard shows under it.
  const talking = listening && !handsFree;

  return (
    <Animated.View entering={FadeInDown.duration(240)} style={styles.card}>
      {talking ? (
        <Animated.View key="listening" entering={FadeIn.duration(160)} style={styles.block}>
          <Text style={styles.kicker}>Listening. Pause when you&rsquo;re done.</Text>
          <Text style={styles.heard} numberOfLines={3}>
            {transcript ? `“${transcript}”` : 'Say what you’re working on, or “next”.'}
          </Text>
        </Animated.View>
      ) : idle ? (
        <Animated.View key="idle" entering={FadeIn.duration(200)} style={styles.block}>
          <Text style={styles.title}>What are you working on?</Text>
          <Text style={styles.sub}>Point the camera at it, tap the mic and say what&rsquo;s wrong. Lensi tags the parts and walks you through it.</Text>
          {state.note ? <Text style={[styles.note, { color: toneColor(state.note.tone, pen) }]}>{state.note.text}</Text> : null}
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chips} style={styles.chipScroll}>
            {STARTERS.map((s) => (
              <PressScale key={s} onPress={() => onSubmit(s)} accessibilityRole="button" accessibilityLabel={s} scaleTo={0.94} haptic="selection">
                <View style={styles.chip}>
                  <Text style={styles.chipText}>{s}</Text>
                </View>
              </PressScale>
            ))}
          </ScrollView>
        </Animated.View>
      ) : working ? (
        <Animated.View key="planning" entering={FadeIn.duration(200)} style={styles.block}>
          <ShinyText text="Looking at it" style={styles.kicker} />
          <Text style={styles.heard} numberOfLines={2}>
            {`“${state.task}”`}
          </Text>
        </Animated.View>
      ) : (
        <Animated.View key={`step-${state.index}-${finished}`} entering={FadeIn.duration(120)} style={styles.block}>
          <View style={styles.head}>
            <Text style={styles.kicker} numberOfLines={1}>
              {finished
                ? 'All done'
                : step
                  ? // While the plan is still arriving, the count isn't known yet.
                    state.streaming
                    ? `Step ${state.index + 1}`
                    : `Step ${state.index + 1} of ${state.steps.length}`
                  : 'What the phone found'}
              {state.title ? ` · ${state.title}` : ''}
            </Text>
            <View style={styles.headButtons}>
              {step ? (
                <PressScale onPress={onRepeat} accessibilityRole="button" accessibilityLabel="Read the step again" scaleTo={0.85} hitSlop={8}>
                  <View style={styles.iconBtn}>
                    <Icon name="voice" size={18} color={paper} />
                  </View>
                </PressScale>
              ) : null}
              <PressScale onPress={onStop} accessibilityRole="button" accessibilityLabel="End this job" scaleTo={0.85} hitSlop={8}>
                <View style={styles.iconBtn}>
                  <Icon name="close" size={17} color={mist} />
                </View>
              </PressScale>
            </View>
          </View>
          {step && !finished ? (
            <Text style={styles.step} accessibilityRole="header">
              {step.text}
            </Text>
          ) : finished ? (
            <Text style={styles.step}>Nice work. Tap the mic and say what&rsquo;s next.</Text>
          ) : null}
          <Status state={state} part={part} watching={watching} busy={busy} pen={pen} handsFree={handsFree} heard={handsFree && listening ? transcript : ''} />
        </Animated.View>
      )}

      <View style={styles.controls}>
        {!idle && !working && !talking && step ? (
          <PressScale onPress={onBack} accessibilityRole="button" accessibilityLabel="Previous step" scaleTo={0.9} disabled={state.index === 0}>
            <View style={[styles.round, state.index === 0 && styles.off]}>
              <Icon name="left" size={20} color={paper} />
            </View>
          </PressScale>
        ) : null}
        {idle && !talking ? (
          <View style={styles.inputWrap}>
            <TextInput
              value={typed}
              onChangeText={setTyped}
              onSubmitEditing={submit}
              placeholder="Or type it"
              placeholderTextColor={faint}
              returnKeyType="go"
              style={styles.input}
              accessibilityLabel="Type what you're working on"
            />
          </View>
        ) : null}
        <MicToggle pen={pen} mode={handsFree ? 'free' : listening ? 'talking' : 'off'} listening={listening} level={level} onPress={onMic} />
        {!idle && !working && !talking && step && !finished ? (
          <>
            <PressScale onPress={onCheck} accessibilityRole="button" accessibilityLabel="Check this step" scaleTo={0.92} disabled={busy}>
              <View style={[compact ? styles.round : styles.pill, busy && styles.off]}>
                <Icon name="eye" size={compact ? 20 : 17} color={paper} />
                {compact ? null : <Text style={styles.pillText}>Check</Text>}
              </View>
            </PressScale>
            <PressScale onPress={onNext} accessibilityRole="button" accessibilityLabel="Next step" scaleTo={0.92} haptic="medium" containerStyle={styles.grow}>
              <View style={[styles.pill, styles.primary, { backgroundColor: pen }]}>
                <Text style={[styles.pillText, { color: ink }]}>{lastStep ? 'Done' : 'Next'}</Text>
                <Icon name={lastStep ? 'check' : 'right'} size={17} color={ink} />
              </View>
            </PressScale>
          </>
        ) : null}
        {finished && !talking ? (
          <PressScale onPress={onStop} accessibilityRole="button" accessibilityLabel="Start another job" scaleTo={0.92} containerStyle={styles.grow}>
            <View style={[styles.pill, styles.primary, { backgroundColor: pen }]}>
              <Text style={[styles.pillText, { color: ink }]}>Another job</Text>
            </View>
          </PressScale>
        ) : null}
      </View>
    </Animated.View>
  );
}

/** One line under the step: what was heard, seen or said, else what is being watched. */
function Status({
  state,
  part,
  watching,
  busy,
  pen,
  handsFree,
  heard,
}: {
  state: GuideState;
  part: GuidePart | null;
  watching: boolean;
  busy: boolean;
  pen: string;
  handsFree: boolean;
  heard: string;
}) {
  // What's being said comes first, even over a check in progress: it may be "stop".
  if (heard) {
    return (
      <Text style={styles.heardLine} numberOfLines={2}>
        {`“${heard}”`}
      </Text>
    );
  }
  if (busy) {
    return <ShinyText text={state.status === 'checking' ? 'Checking' : 'Thinking'} style={styles.status} />;
  }
  if (state.note) {
    return (
      <Animated.Text key={state.note.text} entering={FadeIn.duration(200)} exiting={FadeOut.duration(120)} style={[styles.note, { color: toneColor(state.note.tone, pen) }]}>
        {state.note.text}
      </Animated.Text>
    );
  }
  const say = 'Say “next” when it’s done, or ask anything.';
  if (watching && part) {
    return <Text style={styles.status}>{`Watching the ${part.label.toLowerCase()}. ${handsFree ? say : 'It checks when something changes.'}`}</Text>;
  }
  return handsFree ? <Text style={styles.status}>{say}</Text> : null;
}

function toneColor(tone: 'info' | 'done' | 'warn', pen: string) {
  return tone === 'done' ? pen : tone === 'warn' ? '#FF9C8F' : mist;
}

/**
 * Tap to talk, tap again (or pause) to send: no holding with busy hands.
 * Hands free it stays lit, breathing while it listens; a tap turns it off.
 */
function MicToggle({
  pen,
  mode,
  listening,
  level,
  onPress,
}: {
  pen: string;
  mode: 'off' | 'talking' | 'free';
  listening: boolean;
  level: SharedValue<number>;
  onPress: () => void;
}) {
  const ring = useAnimatedStyle(() => ({ transform: [{ scale: 1 + (listening ? level.value * 0.35 : 0) }] }));
  const lit = mode !== 'off';
  const label = mode === 'free' ? 'Stop hands-free listening' : mode === 'talking' ? 'Stop listening' : 'Talk';
  return (
    <PressScale onPress={onPress} accessibilityRole="button" accessibilityLabel={label} scaleTo={0.9} haptic="medium">
      <Animated.View
        style={[styles.mic, { backgroundColor: lit ? pen : 'rgba(255,255,255,0.12)' }, mode === 'free' && !listening && styles.micWaiting, ring]}
      >
        <Icon name={mode === 'talking' ? 'send' : 'mic'} size={22} color={lit ? ink : paper} />
      </Animated.View>
    </PressScale>
  );
}

const styles = StyleSheet.create({
  card: {
    alignSelf: 'stretch',
    marginHorizontal: 10,
    padding: 18,
    paddingBottom: 16,
    gap: 14,
    borderRadius: 26,
    borderCurve: 'continuous',
    backgroundColor: glassStrong,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
  },
  block: { gap: 8 },
  head: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 10 },
  headButtons: { flexDirection: 'row', gap: 8 },
  kicker: { flexShrink: 1, color: mist, ...face.semibold, fontSize: 14 },
  title: { color: paper, ...face.bold, fontSize: 22, letterSpacing: -0.3 },
  sub: { color: mist, ...face.regular, fontSize: 15, lineHeight: 20 },
  heard: { color: paper, ...face.semibold, fontSize: 20, lineHeight: 25 },
  step: { color: paper, ...face.bold, fontSize: 22, lineHeight: 27, letterSpacing: -0.3 },
  status: { color: faint, ...face.medium, fontSize: 14, lineHeight: 19 },
  heardLine: { color: paper, ...face.semibold, fontSize: 15, lineHeight: 20 },
  note: { ...face.semibold, fontSize: 15, lineHeight: 20 },
  chipScroll: { marginHorizontal: -18, marginTop: 4 },
  chips: { gap: 8, paddingHorizontal: 18 },
  chip: { height: 36, paddingHorizontal: 14, borderRadius: 18, justifyContent: 'center', backgroundColor: 'rgba(255,255,255,0.1)' },
  chipText: { color: paper, ...face.semibold, fontSize: 14 },
  controls: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  round: { width: 52, height: 52, borderRadius: 26, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(255,255,255,0.1)' },
  mic: { width: 56, height: 56, borderRadius: 28, alignItems: 'center', justifyContent: 'center' },
  // Hands free while the app is talking: still on, not listening this second.
  micWaiting: { opacity: 0.55 },
  pill: {
    height: 52,
    paddingHorizontal: 18,
    borderRadius: 26,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    backgroundColor: 'rgba(255,255,255,0.1)',
  },
  primary: { paddingHorizontal: 16 },
  // The primary button takes what's left of the row.
  grow: { flexGrow: 1, flexShrink: 1, minWidth: 90 },
  pillText: { color: paper, ...face.bold, fontSize: 17 },
  off: { opacity: 0.35 },
  iconBtn: { width: 34, height: 34, borderRadius: 17, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(255,255,255,0.08)' },
  inputWrap: { flex: 1, height: 52, borderRadius: 26, paddingHorizontal: 18, justifyContent: 'center', backgroundColor: 'rgba(255,255,255,0.08)' },
  input: { color: paper, ...face.regular, fontSize: 16, paddingVertical: 0, outlineWidth: 0 },
});

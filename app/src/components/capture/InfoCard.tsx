import { useMemo, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeInDown } from 'react-native-reanimated';

import type { Capture, Lens } from '../../lib/types';
import { BlurText } from '../../motion/BlurText';
import { PressScale } from '../../motion/PressScale';
import { ShinyText } from '../../motion/ShinyText';
import { faint, hairline, ink, lensInfo, mist, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Icon } from '../icons/Icon';
import { LensPicker } from './LensPicker';

const SOURCE_COPY: Record<Capture['source'], string> = {
  camera: 'Photo',
  video: 'Video',
  library: 'From Photos',
  files: 'From Files',
  clipboard: 'Pasted',
  voice: 'Spoken',
};

function when(ts: number): string {
  const d = new Date(ts);
  const hh = d.getHours();
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${((hh + 11) % 12) + 1}:${mm} ${hh < 12 ? 'AM' : 'PM'}`;
}

/**
 * What the model said, in reading order: title, one-line summary, actions,
 * then (when expanded) facts and the question thread.
 */
export function InfoCard({
  capture,
  expanded,
  canWalk,
  onWalk,
  onRetry,
  onSuggest,
  onShow,
  onLens,
}: {
  capture: Capture;
  expanded: boolean;
  canWalk: boolean;
  onWalk: () => void;
  onRetry: () => void;
  onSuggest: (q: string) => void;
  /** Point at the parts the latest answer named, again. */
  onShow?: () => void;
  /** Look again through another lens. */
  onLens: (l: Lens) => void;
}) {
  const lens = lensInfo(capture.lens);
  const a = capture.annotation;
  const thinking = capture.status === 'analyzing';
  const hint = capture.subject?.text ?? null;
  const suggestions = useMemo(() => suggest(capture), [capture]);
  // The newest exchange, shown in place of the summary while the card is down.
  const latest = capture.thread.length ? capture.thread[capture.thread.length - 1] : null;
  const [lensOpen, setLensOpen] = useState(false);

  return (
    <View style={styles.wrap}>
      {lensOpen ? (
        <View style={styles.metaSlot}>
          <LensPicker
            lens={capture.lens}
            onPick={(l) => {
              setLensOpen(false);
              if (l !== capture.lens) onLens(l);
            }}
          />
        </View>
      ) : (
        <View style={styles.meta}>
          <PressScale
            onPress={() => setLensOpen(true)}
            scaleTo={0.9}
            haptic="selection"
            hitSlop={10}
            accessibilityRole="button"
            accessibilityLabel={`${lens.name} lens. Change lens`}
          >
            <View style={styles.lensChip}>
              <Text style={[styles.metaText, { color: lens.pen }]}>{lens.name}</Text>
              <Icon name="down" size={10} color={faint} stroke={2.6} />
            </View>
          </PressScale>
          <Text style={[styles.metaFaint, styles.shrink]} numberOfLines={1}>
            · {SOURCE_COPY[capture.source]} · {when(capture.createdAt)}
          </Text>
          {!expanded && a.facts.length ? (
            <Text style={[styles.metaFaint, styles.metaRight]} numberOfLines={1}>
              {a.facts.length} {a.facts.length === 1 ? 'fact' : 'facts'}
            </Text>
          ) : null}
        </View>
      )}

      <View style={styles.titleSlot}>
        {a.title ? (
          <BlurText key={a.title} text={a.title} style={[styles.title, a.title.length > 20 && styles.titleLong]} step={60} duration={700} />
        ) : !thinking ? (
          <Text style={styles.title}>{hint ? hint.charAt(0).toUpperCase() + hint.slice(1) : 'Untitled'}</Text>
        ) : (
          <Animated.View entering={FadeIn} style={styles.waiting}>
            <ShinyText text={hint ? `Looking at the ${hint}` : 'Looking closely'} style={styles.waitingText} dim={0.35} />
          </Animated.View>
        )}
      </View>

      {!expanded && latest ? (
        <Animated.View key={latest.id} entering={FadeInDown.duration(320)} style={styles.latest}>
          <Text style={styles.latestQ} numberOfLines={1}>
            {latest.question}
          </Text>
          {latest.answer.length ? (
            <Animated.Text key={latest.answer.length} entering={FadeIn.duration(260)} style={styles.summary} numberOfLines={2}>
              {latest.answer.join(' ')}
            </Animated.Text>
          ) : latest.steps?.length ? (
            <Text style={styles.summary}>{latest.steps.length} steps, ready when you are.</Text>
          ) : (
            <ShinyText text="Thinking…" style={styles.summary} />
          )}
        </Animated.View>
      ) : a.summary ? (
        <Animated.Text entering={FadeInDown.duration(380).delay(120)} style={styles.summary} numberOfLines={expanded ? undefined : 2}>
          {a.summary}
        </Animated.Text>
      ) : thinking ? (
        <View style={styles.skeletons}>
          <Skeleton w="88%" />
          <Skeleton w="54%" />
        </View>
      ) : null}

      {capture.error ? (
        <Animated.View entering={FadeIn} style={styles.errorRow}>
          <Text style={styles.error}>{capture.error}</Text>
          <PressScale onPress={onRetry} accessibilityRole="button" accessibilityLabel="Try again" scaleTo={0.9}>
            <View style={styles.retry}>
              <Icon name="retry" size={16} />
              <Text style={styles.retryText}>Retry</Text>
            </View>
          </PressScale>
        </Animated.View>
      ) : null}

      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipScroll} contentContainerStyle={styles.chips}>
        {canWalk ? (
          <PressScale onPress={onWalk} accessibilityRole="button" accessibilityLabel="Start the walkthrough" scaleTo={0.93} haptic="medium">
            <View style={[styles.chip, { backgroundColor: lens.pen, borderColor: lens.pen }]}>
              <Icon name="play" size={13} color={ink} />
              <Text style={[styles.chipText, { color: ink }]}>Walk me through</Text>
            </View>
          </PressScale>
        ) : null}
        {onShow ? (
          <Animated.View entering={FadeInDown.springify().damping(18)}>
            <PressScale onPress={onShow} accessibilityRole="button" accessibilityLabel="Show me where" scaleTo={0.93} haptic="medium">
              <View style={[styles.chip, { borderColor: lens.pen }]}>
                <Icon name="pointer" size={14} color={lens.pen} fill={lens.pen} stroke={1.4} />
                <Text style={[styles.chipText, { color: lens.pen }]}>Show me</Text>
              </View>
            </PressScale>
          </Animated.View>
        ) : null}
        {suggestions.map((s, i) => (
          <Animated.View key={s} entering={FadeInDown.delay(200 + i * 70).springify().damping(18)}>
            <PressScale onPress={() => onSuggest(s)} accessibilityRole="button" accessibilityLabel={s} scaleTo={0.93} haptic="selection">
              <View style={styles.chip}>
                <Text style={styles.chipText}>{s}</Text>
              </View>
            </PressScale>
          </Animated.View>
        ))}
      </ScrollView>

      {expanded ? (
        <ScrollView style={styles.more} contentContainerStyle={{ gap: 14, paddingBottom: 8 }} showsVerticalScrollIndicator={false}>
          {a.facts.map((f, i) => (
            <Animated.View key={`f${i}`} entering={FadeInDown.delay(i * 60).duration(320)} style={styles.fact}>
              <Text style={[styles.factN, { color: lens.pen }]}>{String(i + 1).padStart(2, '0')}</Text>
              <Text style={styles.factText}>{f}</Text>
            </Animated.View>
          ))}
          {capture.thread.map((x) => (
            <Animated.View key={x.id} entering={FadeInDown.duration(320)} style={styles.qa}>
              <Text style={styles.q}>{x.question}</Text>
              {x.answer.map((ans, j) => (
                <Animated.Text key={j} entering={FadeIn.duration(260)} style={styles.factText}>
                  {ans}
                </Animated.Text>
              ))}
              {x.steps?.length ? (
                <Text style={styles.stepsNote}>
                  <Text style={{ color: lens.pen }}>{x.steps.length}</Text> STEPS
                </Text>
              ) : null}
              {x.pending && x.answer.length === 0 && !x.steps?.length ? <ShinyText text="Thinking…" style={styles.metaText} /> : null}
            </Animated.View>
          ))}
        </ScrollView>
      ) : null}
    </View>
  );
}

/** The model's own follow-ups when it gave some; otherwise two that fit the lens. */
function suggest(c: Capture): string[] {
  const t = c.annotation.title;
  if (!t || c.status === 'analyzing') return [];
  // Never offer a question that has already been asked.
  const asked = new Set([c.prompt ?? '', ...c.thread.map((e) => e.question)].map((q) => q.trim().toLowerCase()));
  const fresh = (qs: string[]) => qs.filter((q) => q && !asked.has(q.trim().toLowerCase()));
  const fromModel = fresh(c.annotation.suggestions ?? []).slice(0, 2);
  // Eyes only offers just the questions the eyes can answer themselves.
  if (fromModel.length || c.engine === 'vision') return fromModel;
  const bare = t.replace(/^(a|an|the)\s+/i, '');
  // "the car", but "the Breville Barista Express".
  const noun = /^[A-Z][a-z]+$/.test(bare) ? bare.toLowerCase() : bare;
  const thing = t.length > 22 ? 'this' : `the ${noun}`;
  switch (c.lens) {
    case 'fix':
      return fresh([`Why won't ${thing} work?`, 'What should I check first?']);
    case 'shop':
      return fresh(['Is it worth the price?', 'What should I check?']);
    case 'safe':
      return fresh(['Is this safe for kids?', 'Any allergens?']);
    case 'learn':
      return fresh([`How does ${thing} work?`, 'Tell me something surprising']);
    case 'guide':
      return fresh(['Show me the first step', `How do I clean ${thing}?`]);
    default:
      return fresh([`How do I use ${thing}?`, 'What is it for?']);
  }
}

function Skeleton({ w }: { w: `${number}%` }) {
  return <View style={[styles.skeleton, { width: w }]} />;
}

const styles = StyleSheet.create({
  wrap: { gap: 10 },
  meta: { flexDirection: 'row', alignItems: 'center', gap: 6, height: 24 },
  metaSlot: { height: 24, justifyContent: 'center' },
  lensChip: { flexDirection: 'row', alignItems: 'center', gap: 6, height: 24 },
  metaText: { color: paper, ...face.semibold, fontSize: 13 },
  metaFaint: { color: faint, ...face.medium, fontSize: 13 },
  titleSlot: { minHeight: 34, justifyContent: 'center' },
  title: { color: paper, ...face.bold, fontSize: 30, lineHeight: 33, letterSpacing: -0.5 },
  titleLong: { fontSize: 24, lineHeight: 27, letterSpacing: -0.7 },
  metaRight: { marginLeft: 'auto', paddingLeft: 8 },
  shrink: { flexShrink: 1 },
  chipScroll: { flexGrow: 0, marginHorizontal: -18 },
  waiting: { height: 34, justifyContent: 'center' },
  waitingText: { color: paper, ...face.semibold, fontSize: 22, letterSpacing: -0.3 },
  summary: { color: mist, ...face.regular, fontSize: 15.5, lineHeight: 21 },
  latest: { gap: 2 },
  latestQ: { color: paper, ...face.semibold, fontSize: 15, lineHeight: 20 },
  skeletons: { gap: 8, paddingVertical: 4 },
  skeleton: { height: 12, borderRadius: 6, backgroundColor: 'rgba(255,255,255,0.1)' },
  errorRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  error: { flex: 1, color: '#FF9C8F', ...face.medium, fontSize: 14 },
  retry: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 12, height: 32, borderRadius: 16, backgroundColor: 'rgba(255,255,255,0.1)' },
  retryText: { color: paper, ...face.semibold, fontSize: 14 },
  chips: { flexDirection: 'row', gap: 8, marginTop: 2, paddingHorizontal: 18 },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    height: 34,
    paddingHorizontal: 13,
    borderRadius: 17,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    backgroundColor: 'rgba(255,255,255,0.06)',
  },
  chipText: { color: paper, ...face.semibold, fontSize: 14 },
  more: { maxHeight: 260, marginTop: 4 },
  fact: { flexDirection: 'row', gap: 12 },
  factN: { ...face.medium, fontSize: 13, lineHeight: 21, width: 18 },
  factText: { flex: 1, color: paper, ...face.regular, fontSize: 15, lineHeight: 21 },
  qa: { gap: 6, paddingTop: 4, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: hairline },
  q: { color: paper, ...face.semibold, fontSize: 16, lineHeight: 22, marginTop: 8 },
  stepsNote: { color: faint, ...face.medium, fontSize: 12 },
});

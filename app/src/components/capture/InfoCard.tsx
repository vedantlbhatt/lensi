import { useMemo, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeInDown } from 'react-native-reanimated';

import type { Capture, Lens } from '../../lib/types';
import { BlurText } from '../../motion/BlurText';
import { PressScale } from '../../motion/PressScale';
import { ShinyText } from '../../motion/ShinyText';
import { faint, hairline, ink, lensInfo, mist, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';
import { LensPicker } from './LensPicker';

const SOURCE_COPY: Record<Capture['source'], string> = {
  camera: 'PHOTO',
  video: 'VIDEO',
  library: 'FROM PHOTOS',
  files: 'FROM FILES',
  clipboard: 'PASTED',
  voice: 'ASKED ALOUD',
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
  onLens,
}: {
  capture: Capture;
  expanded: boolean;
  canWalk: boolean;
  onWalk: () => void;
  onRetry: () => void;
  onSuggest: (q: string) => void;
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
              <View style={[styles.lensDot, { backgroundColor: lens.pen }]} />
              <Text style={styles.metaText}>{lens.name.toUpperCase()}</Text>
              <Icon name="down" size={10} color={faint} stroke={2.6} />
            </View>
          </PressScale>
          <Text style={styles.metaFaint}>· {SOURCE_COPY[capture.source]}</Text>
          <Text style={styles.metaFaint}>· {when(capture.createdAt)}</Text>
          {!expanded && a.facts.length ? (
            <Text style={[styles.metaFaint, styles.metaRight]}>
              {a.facts.length} {a.facts.length === 1 ? 'FACT' : 'FACTS'} ↑
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
            <Text style={styles.summary}>{latest.steps.length} steps, playing above.</Text>
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
                  {x.steps.length} STEPS · <Text style={{ color: lens.pen }}>PLAY ABOVE</Text>
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
  const fromModel = (c.annotation.suggestions ?? []).filter(Boolean).slice(0, 2);
  if (fromModel.length) return fromModel;
  const thing = t.length > 22 ? 'this' : `the ${t.replace(/^(a|an|the)\s+/i, '')}`;
  switch (c.lens) {
    case 'fix':
      return [`Why won't ${thing} work?`, 'What should I check first?'];
    case 'shop':
      return ['Is it worth the price?', 'What should I check?'];
    case 'safe':
      return ['Is this safe for kids?', 'Any allergens?'];
    case 'learn':
      return [`How does ${thing} work?`, 'Tell me something surprising'];
    case 'guide':
      return ['Show me the first step', `How do I clean ${thing}?`];
    default:
      return [`How do I use ${thing}?`, 'What is it for?'];
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
  lensDot: { width: 7, height: 7, borderRadius: 4 },
  metaText: { color: paper, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.2 },
  metaFaint: { color: faint, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.2 },
  titleSlot: { minHeight: 34, justifyContent: 'center' },
  title: { color: paper, fontFamily: fonts.display, fontSize: 30, lineHeight: 33, letterSpacing: -1 },
  titleLong: { fontSize: 24, lineHeight: 27, letterSpacing: -0.7 },
  metaRight: { marginLeft: 'auto' },
  chipScroll: { flexGrow: 0, marginHorizontal: -18 },
  waiting: { height: 34, justifyContent: 'center' },
  waitingText: { color: paper, fontFamily: fonts.serifItalic, fontSize: 28, letterSpacing: -0.3 },
  summary: { color: mist, fontFamily: fonts.text, fontSize: 15.5, lineHeight: 21 },
  latest: { gap: 2 },
  latestQ: { color: paper, fontFamily: fonts.serifItalic, fontSize: 19, lineHeight: 22 },
  skeletons: { gap: 8, paddingVertical: 4 },
  skeleton: { height: 12, borderRadius: 6, backgroundColor: 'rgba(244,241,234,0.1)' },
  errorRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  error: { flex: 1, color: '#FF9C8F', fontFamily: fonts.textMedium, fontSize: 14 },
  retry: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 12, height: 32, borderRadius: 16, backgroundColor: 'rgba(244,241,234,0.1)' },
  retryText: { color: paper, fontFamily: fonts.textSemi, fontSize: 14 },
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
    backgroundColor: 'rgba(244,241,234,0.06)',
  },
  chipText: { color: paper, fontFamily: fonts.textSemi, fontSize: 14 },
  more: { maxHeight: 260, marginTop: 4 },
  fact: { flexDirection: 'row', gap: 12 },
  factN: { fontFamily: fonts.mono, fontSize: 12, lineHeight: 21, width: 18 },
  factText: { flex: 1, color: paper, fontFamily: fonts.text, fontSize: 15, lineHeight: 21 },
  qa: { gap: 6, paddingTop: 4, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: hairline },
  q: { color: paper, fontFamily: fonts.serifItalic, fontSize: 20, lineHeight: 24, marginTop: 8 },
  stepsNote: { color: faint, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.1 },
});

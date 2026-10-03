import { useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import Animated, {
  FadeIn,
  FadeInDown,
  SlideInDown,
  SlideOutDown,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';

import type { Annotation } from '../lib/useAnnotations';

function Skeleton({ width }: { width: `${number}%` }) {
  const pulse = useSharedValue(0.35);
  useEffect(() => {
    pulse.value = withRepeat(withTiming(0.8, { duration: 650 }), -1, true);
  }, [pulse]);
  const style = useAnimatedStyle(() => ({ opacity: pulse.value }));
  return <Animated.View style={[styles.skeleton, { width }, style]} />;
}

function Close({ onPress }: { onPress: () => void }) {
  return (
    <Pressable onPress={onPress} hitSlop={12} accessibilityLabel="Close" style={styles.close}>
      <View style={[styles.closeBar, { transform: [{ rotate: '45deg' }] }]} />
      <View style={[styles.closeBar, { transform: [{ rotate: '-45deg' }] }]} />
    </Pressable>
  );
}

export function AnnotationSheet({
  item,
  onClose,
  onAsk,
  onRemove,
}: {
  item: Annotation;
  onClose: () => void;
  onAsk: (q: string) => void;
  onRemove: () => void;
}) {
  const [question, setQuestion] = useState('');
  const title = item.title ?? item.label;
  const send = () => {
    const q = question.trim();
    if (!q) return;
    onAsk(q);
    setQuestion('');
  };

  return (
    <Animated.View
      entering={SlideInDown.springify().damping(20).stiffness(180)}
      exiting={SlideOutDown.duration(220)}
      style={styles.sheet}
    >
      <View style={styles.header}>
        <View style={[styles.dot, { backgroundColor: item.color }]} />
        {title ? (
          <Animated.Text key={title} entering={FadeIn.duration(220)} style={styles.title} numberOfLines={1}>
            {title}
          </Animated.Text>
        ) : (
          <Skeleton width="45%" />
        )}
        <Close onPress={onClose} />
      </View>

      <ScrollView style={styles.body} contentContainerStyle={{ gap: 12 }} keyboardShouldPersistTaps="handled">
        {item.summary ? (
          <Animated.Text entering={FadeInDown.duration(260)} style={styles.summary}>
            {item.summary}
          </Animated.Text>
        ) : item.status === 'streaming' ? (
          <View style={{ gap: 8 }}>
            <Skeleton width="92%" />
            <Skeleton width="64%" />
          </View>
        ) : null}

        {item.facts.map((f, i) => (
          <Animated.View key={i} entering={FadeInDown.duration(260)} style={styles.fact}>
            <View style={[styles.factBar, { backgroundColor: item.color }]} />
            <Text style={styles.factText}>{f}</Text>
          </Animated.View>
        ))}

        {item.exchanges.map((x, i) => (
          <Animated.View key={`q${i}`} entering={FadeInDown.duration(260)} style={{ gap: 6 }}>
            <Text style={styles.question}>{x.question}</Text>
            {x.answer.map((a, j) => (
              <Animated.Text key={j} entering={FadeIn.duration(220)} style={styles.factText}>
                {a}
              </Animated.Text>
            ))}
            {x.pending && x.answer.length === 0 ? <Skeleton width="70%" /> : null}
          </Animated.View>
        ))}

        {item.error ? <Text style={styles.error}>{item.error}</Text> : null}
      </ScrollView>

      <View style={styles.askRow}>
        <TextInput
          value={question}
          onChangeText={setQuestion}
          onSubmitEditing={send}
          placeholder="Ask about this"
          placeholderTextColor="rgba(255,255,255,0.45)"
          returnKeyType="send"
          style={styles.input}
        />
        <Pressable onPress={onRemove} hitSlop={8} style={styles.remove}>
          <Text style={styles.removeText}>Remove</Text>
        </Pressable>
      </View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  sheet: {
    position: 'absolute',
    left: 10,
    right: 10,
    bottom: 10,
    maxHeight: '48%',
    borderRadius: 30,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(16,16,19,0.94)',
    paddingTop: 18,
    paddingHorizontal: 20,
    paddingBottom: 14,
  },
  header: { flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 28 },
  dot: { width: 12, height: 12, borderRadius: 6 },
  title: { flex: 1, color: '#fff', fontSize: 21, fontWeight: '700' },
  close: { width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(255,255,255,0.12)', marginLeft: 'auto' },
  closeBar: { position: 'absolute', width: 12, height: 2, borderRadius: 1, backgroundColor: '#fff' },
  body: { marginTop: 12, flexGrow: 0 },
  summary: { color: '#fff', fontSize: 17, lineHeight: 23 },
  fact: { flexDirection: 'row', gap: 12 },
  factBar: { width: 3, borderRadius: 2 },
  factText: { flex: 1, color: '#fff', fontSize: 15, lineHeight: 21 },
  question: { color: '#fff', fontSize: 15, fontWeight: '700' },
  error: { color: '#FF8A80', fontSize: 15 },
  skeleton: { height: 14, borderRadius: 7, backgroundColor: 'rgba(255,255,255,0.18)' },
  askRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 14 },
  input: {
    flex: 1,
    height: 44,
    borderRadius: 22,
    paddingHorizontal: 16,
    backgroundColor: 'rgba(255,255,255,0.1)',
    color: '#fff',
    fontSize: 16,
  },
  remove: { paddingHorizontal: 6, height: 44, justifyContent: 'center' },
  removeText: { color: '#FF8A80', fontSize: 15, fontWeight: '600' },
});

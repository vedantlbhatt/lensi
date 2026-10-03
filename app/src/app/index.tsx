import { useRef, useState } from 'react';
import { KeyboardAvoidingView, Pressable, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeOut, LinearTransition } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { isSupported, LensiARView, type LensiARViewRef, type TrackingEvent } from '../../modules/lensi-ar/src';
import { AnnotationSheet } from '../components/AnnotationSheet';
import { LensBar, lensColor } from '../components/LensBar';
import { Shutter } from '../components/Shutter';
import type { Lens } from '../lib/annotate';
import { useAnnotations } from '../lib/useAnnotations';

const HINTS: Record<string, string> = {
  initializing: 'Move your phone slowly',
  excessiveMotion: 'Slow down a little',
  insufficientFeatures: 'Point at something with more detail',
  relocalizing: 'Finding your place again',
};

export default function Camera() {
  const insets = useSafeAreaInsets();
  const view = useRef<LensiARViewRef>(null);
  const [lens, setLens] = useState<Lens>('identify');
  const [focus, setFocus] = useState<string | null>(null);
  const [tracking, setTracking] = useState<TrackingEvent>({ state: 'limited', reason: 'initializing' });
  const { items, selected, setSelectedId, onSelect, ask, remove, clear } = useAnnotations(view);

  if (!isSupported) {
    return (
      <View style={[styles.root, styles.center]}>
        <Text style={styles.unsupported}>Lensi needs an iPhone with a camera.</Text>
      </View>
    );
  }

  const hint = tracking.state === 'limited' ? HINTS[tracking.reason] : null;

  return (
    <View style={styles.root}>
      <LensiARView
        ref={view}
        style={StyleSheet.absoluteFill}
        showDetections={!selected}
        onSelect={(e) => onSelect(e.nativeEvent, lens)}
        onFocusChange={(e) => setFocus(e.nativeEvent.label)}
        onTrackingChange={(e) => setTracking(e.nativeEvent)}
        onPinTap={(e) => setSelectedId(e.nativeEvent.id)}
      />

      <View style={[styles.top, { paddingTop: insets.top + 8 }]} pointerEvents="box-none">
        {hint ? (
          <Animated.View entering={FadeIn} exiting={FadeOut} style={styles.hint}>
            <Text style={styles.hintText}>{hint}</Text>
          </Animated.View>
        ) : null}
        {items.length > 0 ? (
          <Animated.View entering={FadeIn} exiting={FadeOut} style={styles.clearWrap}>
            <Pressable onPress={clear} hitSlop={8} style={styles.clear}>
              <Text style={styles.clearText}>Clear {items.length}</Text>
            </Pressable>
          </Animated.View>
        ) : null}
      </View>

      <KeyboardAvoidingView behavior="padding" style={StyleSheet.absoluteFill} pointerEvents="box-none">
        {selected ? (
          <AnnotationSheet
            key={selected.id}
            item={selected}
            onClose={() => setSelectedId(null)}
            onAsk={(q) => ask(selected.id, q)}
            onRemove={() => remove(selected.id)}
          />
        ) : (
          <Animated.View
            entering={FadeIn.duration(200)}
            exiting={FadeOut.duration(150)}
            layout={LinearTransition}
            style={[styles.bottom, { paddingBottom: insets.bottom + 14 }]}
          >
            <View style={styles.focusRow}>
              {focus ? (
                <Animated.Text key={focus} entering={FadeIn.duration(150)} style={styles.focus}>
                  {focus}
                </Animated.Text>
              ) : null}
            </View>
            <Shutter color={lensColor(lens)} onPress={() => view.current?.capture()} />
            <LensBar lens={lens} onChange={setLens} />
          </Animated.View>
        )}
      </KeyboardAvoidingView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  center: { alignItems: 'center', justifyContent: 'center', padding: 32 },
  unsupported: { color: '#fff', fontSize: 17, textAlign: 'center' },
  top: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  hint: { paddingHorizontal: 14, height: 34, borderRadius: 17, justifyContent: 'center', backgroundColor: 'rgba(12,12,14,0.7)' },
  hintText: { color: '#fff', fontSize: 15, fontWeight: '600' },
  clearWrap: { position: 'absolute', right: 16, bottom: 0 },
  clear: { paddingHorizontal: 14, height: 34, borderRadius: 17, justifyContent: 'center', backgroundColor: 'rgba(12,12,14,0.7)' },
  clearText: { color: '#fff', fontSize: 15, fontWeight: '600' },
  bottom: { position: 'absolute', left: 0, right: 0, bottom: 0, alignItems: 'center', gap: 18 },
  focusRow: { height: 30, justifyContent: 'center' },
  focus: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
    paddingHorizontal: 14,
    paddingVertical: 5,
    borderRadius: 15,
    overflow: 'hidden',
    backgroundColor: 'rgba(12,12,14,0.6)',
  },
});

import { useEffect, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { FadeIn, FadeOut, useAnimatedStyle, ZoomIn } from 'react-native-reanimated';

import { haptic } from '../../lib/haptics';
import { useVoice } from '../../lib/voice';
import { toast } from '../ui/Toast';

import { PressScale } from '../../motion/PressScale';
import { faint, hairline, ink, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';

/** Type a follow-up, or hold the mic and say it; the words stream into the field. */
export function AskBar({
  pen,
  busy,
  onAsk,
  onFocus,
  placeholder = 'Ask about this, or how to…',
}: {
  pen: string;
  busy: boolean;
  onAsk: (q: string, byVoice?: boolean) => void;
  onFocus?: () => void;
  placeholder?: string;
}) {
  const [q, setQ] = useState('');
  const voice = useVoice();
  useEffect(() => {
    if (voice.error) toast(voice.error);
  }, [voice.error]);
  useEffect(() => {
    if (voice.listening) setQ(voice.transcript);
  }, [voice.listening, voice.transcript]);
  const hold = Gesture.LongPress()
    .minDuration(120)
    .maxDistance(200)
    .runOnJS(true)
    .onStart(() => {
      haptic.tap();
      void voice.start();
    })
    .onFinalize(async () => {
      const wasListening = voice.isListening();
      const said = await voice.stop();
      if (!wasListening) return;
      if (said) {
        onAsk(said, true);
        setQ('');
      } else {
        toast("Didn't catch that.");
      }
    });
  const glow = useAnimatedStyle(() => ({ transform: [{ scale: 1 + voice.level.value * 0.35 }], opacity: 0.25 + voice.level.value * 0.5 }));
  const send = () => {
    const s = q.trim();
    if (!s || busy) return;
    onAsk(s);
    setQ('');
  };
  const hasText = q.trim().length > 0;
  return (
    <View style={styles.bar}>
      <TextInput
        value={q}
        onChangeText={setQ}
        onSubmitEditing={send}
        onFocus={onFocus}
        placeholder={voice.listening ? 'Listening…' : placeholder}
        placeholderTextColor={faint}
        returnKeyType="send"
        style={[styles.input, voice.listening && styles.inputListening]}
        editable={!voice.listening}
        selectionColor={pen}
        accessibilityLabel="Ask a question about this capture"
      />
      {hasText && !voice.listening ? (
        <Animated.View entering={ZoomIn.springify().damping(14)} exiting={FadeOut.duration(120)}>
          <PressScale onPress={send} accessibilityRole="button" accessibilityLabel="Send" scaleTo={0.85}>
            <View style={[styles.send, { backgroundColor: pen }]}>
              <Icon name="send" size={20} color={ink} stroke={2.3} />
            </View>
          </PressScale>
        </Animated.View>
      ) : (
        <GestureDetector gesture={hold}>
          <Animated.View entering={FadeIn.duration(160)} style={styles.sendGhost} accessibilityRole="button" accessibilityLabel="Hold to ask out loud" collapsable={false}>
            {voice.listening ? <Animated.View style={[styles.micGlow, { backgroundColor: pen }, glow]} /> : null}
            <Icon name="mic" size={19} color={voice.listening ? pen : faint} stroke={1.7} fill={voice.listening ? pen : undefined} />
          </Animated.View>
        </GestureDetector>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    height: 50,
    paddingLeft: 16,
    paddingRight: 5,
    borderRadius: 25,
    backgroundColor: 'rgba(244,241,234,0.07)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
  },
  input: { flex: 1, color: paper, fontFamily: fonts.text, fontSize: 16, paddingVertical: 0, height: 48, outlineWidth: 0 },
  send: { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center' },
  sendGhost: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  micGlow: { position: 'absolute', width: 34, height: 34, borderRadius: 17 },
  inputListening: { fontFamily: fonts.serifItalic, fontSize: 18 },
});

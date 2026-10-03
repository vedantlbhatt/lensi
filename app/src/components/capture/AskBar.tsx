import { useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import Animated, { FadeIn, FadeOut, ZoomIn } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { faint, hairline, ink, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';

/** Type a follow-up, or hold the mic to say it. */
export function AskBar({
  pen,
  busy,
  onAsk,
  onFocus,
  placeholder = 'Ask about this, or how to…',
}: {
  pen: string;
  busy: boolean;
  onAsk: (q: string) => void;
  onFocus?: () => void;
  placeholder?: string;
}) {
  const [q, setQ] = useState('');
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
        placeholder={placeholder}
        placeholderTextColor={faint}
        returnKeyType="send"
        style={styles.input}
        selectionColor={pen}
        accessibilityLabel="Ask a question about this capture"
      />
      {hasText ? (
        <Animated.View entering={ZoomIn.springify().damping(14)} exiting={FadeOut.duration(120)}>
          <PressScale onPress={send} accessibilityRole="button" accessibilityLabel="Send" scaleTo={0.85}>
            <View style={[styles.send, { backgroundColor: pen }]}>
              <Icon name="send" size={20} color={ink} stroke={2.3} />
            </View>
          </PressScale>
        </Animated.View>
      ) : (
        <Animated.View entering={FadeIn.duration(160)} style={styles.sendGhost}>
          <Icon name="spark" size={18} color={faint} stroke={1.5} />
        </Animated.View>
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
  input: { flex: 1, color: paper, fontFamily: fonts.text, fontSize: 16, paddingVertical: 0, height: 48 },
  send: { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center' },
  sendGhost: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
});

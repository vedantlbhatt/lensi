import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, TextInput, View } from 'react-native';
import Animated, { FadeInDown } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { faint, hairline, ink, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Icon } from '../icons/Icon';
import { LABEL } from './layout';

/**
 * Renaming a label, in the label's own type: the card becomes a single field
 * with the old name selected, so typing replaces it.
 */
export function LabelEditor({
  initial,
  pen,
  onDone,
  onCancel,
}: {
  initial: string;
  pen: string;
  onDone: (label: string) => void;
  onCancel: () => void;
}) {
  const [v, setV] = useState(initial);
  const input = useRef<TextInput>(null);
  // Focus once the card has swapped in; focusing mid-transition can be dropped.
  useEffect(() => {
    const t = setTimeout(() => input.current?.focus(), 80);
    return () => clearTimeout(t);
  }, []);
  const save = () => {
    const t = v.replace(/\s+/g, ' ').trim();
    if (t && t !== initial) onDone(t);
    else onCancel();
  };
  return (
    <Animated.View entering={FadeInDown.duration(240)} style={styles.wrap}>
      <View style={styles.head}>
        <Text style={styles.kicker}>Rename label</Text>
        <PressScale onPress={onCancel} scaleTo={0.9} hitSlop={10} accessibilityRole="button" accessibilityLabel="Cancel">
          <Text style={styles.cancel}>Cancel</Text>
        </PressScale>
      </View>
      <View style={styles.bar}>
        <TextInput
          ref={input}
          value={v}
          onChangeText={setV}
          onSubmitEditing={save}
          selectTextOnFocus
          returnKeyType="done"
          maxLength={LABEL.maxChars * 2}
          autoCorrect={false}
          autoCapitalize="none"
          placeholder="Call it…"
          placeholderTextColor={faint}
          selectionColor={pen}
          style={styles.input}
          accessibilityLabel="Label name"
        />
        <PressScale onPress={save} scaleTo={0.85} accessibilityRole="button" accessibilityLabel="Save label">
          <View style={[styles.ok, { backgroundColor: pen }]}>
            <Icon name="check" size={18} color={ink} stroke={2.4} />
          </View>
        </PressScale>
      </View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  wrap: { gap: 12, paddingBottom: 2 },
  head: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', height: 24 },
  kicker: { color: faint, ...face.medium, fontSize: 12 },
  cancel: { color: paper, ...face.semibold, fontSize: 15 },
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    height: 50,
    paddingLeft: 16,
    paddingRight: 5,
    borderRadius: 16,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(11,11,12,0.84)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
  },
  input: { flex: 1, minWidth: 0, color: paper, ...face.medium, fontSize: 17, height: 48, paddingVertical: 0, outlineWidth: 0 },
  ok: { width: 40, height: 40, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },
});

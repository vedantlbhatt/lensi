import { Linking, StyleSheet, Text, View } from 'react-native';
import Animated, { FadeIn, FadeInDown } from 'react-native-reanimated';

import { PressScale } from '../../motion/PressScale';
import { hairline, ink, mist, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { Icon } from '../icons/Icon';

/**
 * The camera never started: no permission, or the sensor failed. Says which,
 * offers the way out, and keeps Drop one tap away so the app still works.
 */
export function CameraBlocked({
  reason,
  pen,
  onDrop,
  onRetry,
}: {
  reason: 'cameraDenied' | 'failed';
  pen: string;
  onDrop: () => void;
  onRetry: () => void;
}) {
  const denied = reason === 'cameraDenied';
  return (
    <Animated.View entering={FadeIn.duration(260)} style={[StyleSheet.absoluteFill, styles.wrap]} pointerEvents="box-none">
      <Animated.View entering={FadeInDown.delay(120).springify().damping(18)} style={styles.card}>
        <Text style={styles.lead}>{denied ? 'Lensi needs' : 'The camera'}</Text>
        <Text style={[styles.big, { color: pen }]}>{denied ? 'the camera' : "didn't start"}</Text>
        <Text style={styles.body}>
          {denied
            ? 'Allow it in Settings to point and ask. Photos, videos and files still work from Drop.'
            : 'Something else may be using it. Try again, or drop in a photo instead.'}
        </Text>
        <View style={styles.row}>
          <PressScale
            onPress={() => (denied ? void Linking.openSettings() : onRetry())}
            scaleTo={0.94}
            haptic="medium"
            accessibilityRole="button"
            accessibilityLabel={denied ? 'Open Settings' : 'Try again'}
          >
            <View style={[styles.primary, { backgroundColor: pen }]}>
              <Text style={styles.primaryText}>{denied ? 'Open Settings' : 'Try again'}</Text>
            </View>
          </PressScale>
          <PressScale onPress={onDrop} scaleTo={0.94} accessibilityRole="button" accessibilityLabel="Drop something in">
            <View style={styles.secondary}>
              <Icon name="drop" size={17} />
              <Text style={styles.secondaryText}>Drop</Text>
            </View>
          </PressScale>
        </View>
      </Animated.View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  wrap: { alignItems: 'center', justifyContent: 'center', paddingHorizontal: 28, backgroundColor: ink },
  card: { alignSelf: 'stretch', gap: 2 },
  lead: { color: paper, ...face.semibold, fontSize: 29, lineHeight: 35, letterSpacing: -0.3 },
  big: { ...face.bold, fontSize: 44, lineHeight: 46, letterSpacing: -0.8 },
  body: { color: mist, ...face.regular, fontSize: 16, lineHeight: 22, marginTop: 12, maxWidth: 320 },
  row: { flexDirection: 'row', gap: 10, marginTop: 22 },
  primary: { height: 48, paddingHorizontal: 20, borderRadius: 24, alignItems: 'center', justifyContent: 'center' },
  primaryText: { color: ink, ...face.bold, fontSize: 16 },
  secondary: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    height: 48,
    paddingHorizontal: 18,
    borderRadius: 24,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    backgroundColor: 'rgba(255,255,255,0.07)',
  },
  secondaryText: { color: paper, ...face.semibold, fontSize: 16 },
});

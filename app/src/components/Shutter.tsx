import { Pressable, StyleSheet } from 'react-native';
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  withSequence,
  withSpring,
  withTiming,
} from 'react-native-reanimated';

export function Shutter({ color, onPress }: { color: string; onPress: () => void }) {
  const press = useSharedValue(0);
  const ring = useAnimatedStyle(() => ({ transform: [{ scale: 1 - press.value * 0.08 }] }));
  const disc = useAnimatedStyle(() => ({
    backgroundColor: color,
    transform: [{ scale: 1 - press.value * 0.18 }],
  }));

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Annotate what the camera is pointing at"
      onPressIn={() => (press.value = withSpring(1, { damping: 15, stiffness: 400 }))}
      onPressOut={() => (press.value = withSpring(0, { damping: 10, stiffness: 260 }))}
      onPress={() => {
        press.value = withSequence(withTiming(1, { duration: 60 }), withSpring(0, { damping: 9, stiffness: 240 }));
        onPress();
      }}
    >
      <Animated.View style={[styles.ring, ring]}>
        <Animated.View style={[styles.disc, disc]} />
      </Animated.View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  ring: {
    width: 76,
    height: 76,
    borderRadius: 38,
    borderWidth: 4,
    borderColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  disc: { width: 58, height: 58, borderRadius: 29 },
});

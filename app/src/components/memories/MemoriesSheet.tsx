import { Image } from 'expo-image';
import { LinearGradient } from 'expo-linear-gradient';
import { useEffect, useRef } from 'react';
import { FlatList, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { FadeInDown, useAnimatedStyle, useSharedValue, withSpring, withTiming, Easing } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { scheduleOnRN } from 'react-native-worklets';

import { useCaptureList } from '../../lib/store';
import type { Capture } from '../../lib/types';
import { Grain } from '../../motion/Grain';
import { PressScale } from '../../motion/PressScale';
import { RotatingText } from '../../motion/RotatingText';
import { springs } from '../../theme/motion';
import { faint, ink, lensInfo, mist, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';
import { Icon } from '../icons/Icon';
import type { Rect } from '../capture/CaptureView';

/**
 * Every capture, newest first, as prints on a dark table. Slides up from the
 * camera; drag down to put it away. Tapping a print zooms it open.
 */
export function MemoriesSheet({ onOpen, onClose }: { onOpen: (id: string, from: Rect) => void; onClose: () => void }) {
  const { height, width } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const list = useCaptureList();
  const y = useSharedValue(height);
  const drag = useSharedValue(0);

  useEffect(() => {
    y.value = withSpring(0, springs.arrive);
  }, [y]);

  const close = () => {
    y.value = withTiming(height, { duration: 320, easing: Easing.bezier(0.5, 0, 0.75, 0) }, (done) => {
      if (done) scheduleOnRN(onClose);
    });
  };

  const pan = Gesture.Pan()
    .activeOffsetY([14, 999])
    .onUpdate((e) => {
      drag.value = Math.max(0, e.translationY);
    })
    .onEnd((e) => {
      if (e.translationY > 120 || e.velocityY > 800) {
        drag.value = withTiming(0, { duration: 1 });
        y.value = withTiming(height, { duration: 280 }, (done) => {
          if (done) scheduleOnRN(onClose);
        });
      } else drag.value = withSpring(0, springs.arrive);
    });

  const sheet = useAnimatedStyle(() => ({ transform: [{ translateY: y.value + drag.value }] }));
  const col = (width - 16 * 2 - 10) / 2;

  return (
    <Animated.View style={[StyleSheet.absoluteFill, styles.sheet, sheet]}>
      <Grain opacity={0.05} />
      <GestureDetector gesture={pan}>
        <View style={[styles.head, { paddingTop: insets.top + 10 }]}>
          <View style={styles.grab} />
          <View style={styles.headRow}>
            <View>
              <Text style={styles.title}>Memories</Text>
              <Text style={styles.count}>
                {list.length} {list.length === 1 ? 'CAPTURE' : 'CAPTURES'} · SAVED ON THIS PHONE
              </Text>
            </View>
            <PressScale onPress={close} accessibilityRole="button" accessibilityLabel="Back to camera" scaleTo={0.85}>
              <View style={styles.close}>
                <Icon name="down" size={22} />
              </View>
            </PressScale>
          </View>
        </View>
      </GestureDetector>

      {list.length === 0 ? (
        <View style={styles.empty}>
          <Text style={styles.emptyTitle}>Nothing here yet.</Text>
          <View style={styles.emptyRow}>
            <Text style={styles.emptyText}>Point Lensi at </Text>
            <RotatingText words={['a coffee machine', 'a breaker box', 'a houseplant', 'a router', 'your car']} style={[styles.emptyText, { color: paper }]} />
          </View>
          <Text style={styles.emptyHint}>TAP FOR A PHOTO · HOLD FOR VIDEO · DROP ANYTHING IN</Text>
        </View>
      ) : (
        <FlatList
          data={list}
          keyExtractor={(c) => c.id}
          numColumns={2}
          columnWrapperStyle={{ gap: 10 }}
          contentContainerStyle={{ paddingHorizontal: 16, paddingBottom: insets.bottom + 24, gap: 10 }}
          renderItem={({ item, index }) => <Tile c={item} index={index} width={col} onOpen={onOpen} />}
          showsVerticalScrollIndicator={false}
        />
      )}
    </Animated.View>
  );
}

function Tile({ c, index, width, onOpen }: { c: Capture; index: number; width: number; onOpen: (id: string, from: Rect) => void }) {
  const ref = useRef<View>(null);
  const lens = lensInfo(c.lens);
  const h = width * 1.3;
  const open = () => {
    ref.current?.measureInWindow((x, y, w, hh) => onOpen(c.id, { x, y, w, h: hh }));
  };
  return (
    <Animated.View entering={FadeInDown.delay(Math.min(index, 10) * 45).springify().damping(18)}>
      <PressScale onPress={open} scaleTo={0.95} accessibilityRole="button" accessibilityLabel={c.annotation.title ?? 'Capture'}>
        <View ref={ref} collapsable={false} style={[styles.tile, { width, height: h }]}>
          <Image source={{ uri: c.media.stillUri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={160} />
          <LinearGradient colors={['rgba(11,11,12,0)', 'rgba(11,11,12,0.88)']} style={styles.fade} />
          {c.media.kind === 'video' ? (
            <View style={styles.videoTag}>
              <Icon name="play" size={10} color={ink} />
            </View>
          ) : c.moments.length > 1 ? (
            <View style={styles.photosTag} accessibilityLabel={`${c.moments.length} photos`}>
              <Icon name="stack" size={11} color={ink} stroke={2.2} />
              <Text style={styles.photosText}>{c.moments.length}</Text>
            </View>
          ) : null}
          <View style={styles.tileText}>
            <View style={styles.tileMeta}>
              <View style={[styles.dot, { backgroundColor: lens.pen }]} />
              <Text style={styles.tileLens}>{lens.name.toUpperCase()}</Text>
            </View>
            <Text style={styles.tileTitle} numberOfLines={2}>
              {c.annotation.title ?? (c.status === 'analyzing' ? 'Still looking…' : 'Untitled')}
            </Text>
          </View>
        </View>
      </PressScale>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  sheet: { backgroundColor: ink, zIndex: 20 },
  head: { paddingHorizontal: 18, paddingBottom: 16 },
  grab: { alignSelf: 'center', width: 38, height: 4, borderRadius: 2, backgroundColor: 'rgba(244,241,234,0.2)', marginBottom: 14 },
  headRow: { flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'space-between' },
  title: { color: paper, fontFamily: fonts.serifItalic, fontSize: 50, lineHeight: 52, letterSpacing: -1 },
  count: { color: faint, fontFamily: fonts.mono, fontSize: 11, letterSpacing: 1.2, marginTop: 2 },
  close: { width: 44, height: 44, borderRadius: 22, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(244,241,234,0.08)' },
  tile: { borderRadius: 20, overflow: 'hidden', backgroundColor: '#1a1a1c', borderCurve: 'continuous' },
  fade: { position: 'absolute', left: 0, right: 0, bottom: 0, height: '55%' },
  tileText: { position: 'absolute', left: 12, right: 12, bottom: 12, gap: 5 },
  tileMeta: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  dot: { width: 6, height: 6, borderRadius: 3 },
  tileLens: { color: mist, fontFamily: fonts.mono, fontSize: 10, letterSpacing: 1.2 },
  tileTitle: { color: paper, fontFamily: fonts.display, fontSize: 18, lineHeight: 20, letterSpacing: -0.5 },
  videoTag: { position: 'absolute', top: 10, right: 10, width: 22, height: 22, borderRadius: 11, backgroundColor: paper, alignItems: 'center', justifyContent: 'center' },
  photosTag: {
    position: 'absolute',
    top: 10,
    right: 10,
    height: 22,
    paddingHorizontal: 7,
    borderRadius: 11,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    backgroundColor: paper,
  },
  photosText: { color: ink, fontFamily: fonts.mono, fontSize: 11 },
  empty: { flex: 1, paddingHorizontal: 24, paddingTop: 60, gap: 10 },
  emptyTitle: { color: paper, fontFamily: fonts.display, fontSize: 30, letterSpacing: -1 },
  emptyRow: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'baseline' },
  emptyText: { color: mist, fontFamily: fonts.serifItalic, fontSize: 24 },
  emptyHint: { color: faint, fontFamily: fonts.mono, fontSize: 10.5, letterSpacing: 1.2, marginTop: 18 },
});

import { BlurView } from 'expo-blur';
import { useEffect, useState } from 'react';
import { Alert, Platform, Pressable, ScrollView, StyleSheet, Switch, Text, TextInput, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  FadeIn,
  FadeOut,
  LinearTransition,
  SlideInDown,
  SlideOutDown,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
} from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LensiAR, type IntelligenceStatus } from '../../../modules/lensi-ar/src';
import { cloudEngine, serverURL } from '../../lib/engines/cloud';
import { cancel } from '../../lib/pipeline';
import { useLiveStats } from '../../lib/liveStats';
import { setSettings, useSettings, type Brain } from '../../lib/settings';
import { clearCaptures, useCaptureList } from '../../lib/store';
import { PressScale } from '../../motion/PressScale';
import { faint, glassStrong, hairline, ink, mist, paper } from '../../theme/tokens';
import { face } from '../../theme/type';
import { calm } from '../../theme/motion';

const BRAINS: { key: Brain; name: string; note: string }[] = [
  { key: 'auto', name: 'Auto', note: 'On-device first, then the cloud, then eyes only.' },
  { key: 'apple', name: 'On-device', note: 'Apple Intelligence. Private, offline, free.' },
  { key: 'cloud', name: 'Claude', note: 'Sharper answers via your Lensi server.' },
  { key: 'vision', name: 'Eyes only', note: 'No model: outlines, text and codes found on the phone.' },
];

export function SettingsSheet({ pen, onClose }: { pen: string; onClose: () => void }) {
  const s = useSettings();
  const insets = useSafeAreaInsets();
  const screen = useWindowDimensions();
  const captures = useCaptureList();
  const [apple, setApple] = useState<IntelligenceStatus | null>(null);
  const live = useLiveStats();
  // Pull the sheet down by its handle to put it away.
  const pull = useSharedValue(0);
  const drag = Gesture.Pan()
    .activeOffsetY([-8, 8])
    .onUpdate((e) => {
      pull.value = Math.max(0, e.translationY);
    })
    .onEnd((e) => {
      if (e.translationY > 110 || e.velocityY > 800) scheduleOnRN(onClose);
      else pull.value = withSpring(0, calm({ damping: 20, stiffness: 260 }));
    });
  const pulled = useAnimatedStyle(() => ({ transform: [{ translateY: pull.value }] }));
  const [cloudOk, setCloudOk] = useState<boolean | null>(null);
  useEffect(() => {
    LensiAR.intelligenceStatus().then(setApple).catch(() => setApple({ available: false, images: false, reason: 'Unavailable' }));
  }, []);
  useEffect(() => {
    setCloudOk(null);
    cloudEngine.available().then(setCloudOk);
  }, [s.serverURL]);

  return (
    <View style={StyleSheet.absoluteFill}>
      <Animated.View entering={FadeIn.duration(180)} exiting={FadeOut.duration(180)} style={[StyleSheet.absoluteFill, styles.scrim]}>
        <Pressable style={StyleSheet.absoluteFill} onPress={onClose} accessibilityLabel="Close settings" />
      </Animated.View>
      <Animated.View style={[styles.sheetPos, pulled]} pointerEvents="box-none">
        <Animated.View
          entering={SlideInDown.duration(240)}
          exiting={SlideOutDown.duration(220)}
          style={[styles.sheet, { maxHeight: screen.height - insets.top - 24 }]}
        >
          {/* Frosted, so the camera behind reads as colour rather than as words. */}
          {Platform.OS !== 'android' ? <BlurView intensity={36} tint="dark" style={StyleSheet.absoluteFill} /> : null}
          <View style={[StyleSheet.absoluteFill, styles.tint]} />
          <GestureDetector gesture={drag}>
            <View style={styles.head}>
              <View style={styles.grab} />
              <Text style={styles.h1} accessibilityRole="header">
                Settings
              </Text>
            </View>
          </GestureDetector>
          <ScrollView
            style={styles.scroll}
            contentContainerStyle={{ paddingBottom: insets.bottom + 18 }}
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
            automaticallyAdjustKeyboardInsets
          >
            <Text style={styles.section}>Brain</Text>
            <View style={styles.segment}>
              {BRAINS.map((b) => {
                const on = s.brain === b.key;
                return (
                  <PressScale key={b.key} onPress={() => setSettings({ brain: b.key })} scaleTo={0.94} haptic="selection" containerStyle={{ flex: 1 }} style={{ flex: 1 }} accessibilityRole="button" accessibilityLabel={b.name}>
                    <Animated.View layout={LinearTransition.duration(240)} style={[styles.segItem, on && { backgroundColor: pen }]}>
                      <Text style={[styles.segText, on && { color: ink }]} numberOfLines={1}>
                        {b.name}
                      </Text>
                    </Animated.View>
                  </PressScale>
                );
              })}
            </View>
            <Animated.Text key={s.brain} entering={FadeIn.duration(200)} style={styles.note}>
              {BRAINS.find((b) => b.key === s.brain)?.note}
            </Animated.Text>

            <View style={styles.status}>
              <StatusLine label="Apple Intelligence" ok={apple?.available ?? null} detail={apple ? (apple.available ? (apple.images ? 'Ready · sees images' : 'Ready · text only') : apple.reason) : 'Checking…'} pen={pen} />
              <StatusLine label="Lensi server" ok={cloudOk} detail={cloudOk === null ? 'Checking…' : cloudOk ? serverURL() : `Not reachable at ${serverURL()}`} pen={pen} />
              {/* EdgeTAM's real speed here, once something's pinned: how often it looks, how late each answer is,
                  and whether the phone is hot enough that it looks less often (LensiARView.segmentLive). */}
              <StatusLine
                label="Following"
                ok={live ? live.looksPerSecond >= 10 && live.latencyMs <= 120 : null}
                detail={
                  live
                    ? `${live.looksPerSecond.toFixed(1)} a second · ${Math.round(live.latencyMs)} ms late${
                        live.thermal >= 2 ? ' · hot, slowed down' : live.thermal === 1 ? ' · warm' : ''
                      }`
                    : 'Pin something to measure'
                }
                pen={pen}
              />
            </View>

            <Text style={styles.section}>Behaviour</Text>
            <Row label="Read steps aloud" value={s.narrate} onChange={(v) => setSettings({ narrate: v })} pen={pen} />
            <Row label="Keep listening during a job" value={s.handsFree} onChange={(v) => setSettings({ handsFree: v })} pen={pen} />
            <Row label="Live outlines on the camera" value={s.liveBrackets} onChange={(v) => setSettings({ liveBrackets: v })} pen={pen} />
            <Row label="Haptics" value={s.haptics} onChange={(v) => setSettings({ haptics: v })} pen={pen} />

            <Text style={styles.section}>Server URL</Text>
            <TextInput
              value={s.serverURL}
              onChangeText={(v) => setSettings({ serverURL: v })}
              placeholder={serverURL()}
              placeholderTextColor={faint}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              style={styles.input}
              selectionColor={pen}
            />

            <Text style={styles.section}>Memories</Text>
            <View style={styles.row}>
              <Text style={styles.rowText}>
                {captures.length} {captures.length === 1 ? 'capture' : 'captures'} on this phone
              </Text>
              {captures.length ? (
                <PressScale
                  onPress={() => {
                    const wipe = () => {
                      for (const c of captures) cancel(c.id);
                      clearCaptures();
                    };
                    if (Platform.OS === 'web') {
                      if ((globalThis as { confirm?: (m: string) => boolean }).confirm?.('Delete every capture?')) wipe();
                      return;
                    }
                    Alert.alert('Delete every capture?', 'Photos, labels and answers saved in Lensi are removed from this phone.', [
                      { text: 'Cancel', style: 'cancel' },
                      { text: 'Delete all', style: 'destructive', onPress: wipe },
                    ]);
                  }}
                  scaleTo={0.92}
                  haptic="medium"
                  accessibilityRole="button"
                  accessibilityLabel="Delete all captures"
                >
                  <View style={styles.danger}>
                    <Text style={styles.dangerText}>Delete all</Text>
                  </View>
                </PressScale>
              ) : null}
            </View>

            <Text style={styles.section}>Made with</Text>
            <Text style={styles.credits}>
              Apple Foundation Models · Vision · ARKit. MobileSAM (Apache-2.0) for part outlines, YOLO11n (AGPL-3.0) for
              live detection. Type: SF Pro, the iPhone's own (Inter in the web preview). Motion ideas
              from React Bits, rebuilt for React Native. Demo photos from the Segment Anything and OpenCV samples
              (Apache-2.0).
            </Text>
          </ScrollView>
        </Animated.View>
      </Animated.View>
    </View>
  );
}

function StatusLine({ label, ok, detail, pen }: { label: string; ok: boolean | null; detail: string; pen: string }) {
  return (
    <View style={styles.statusRow}>
      <Text style={styles.statusLabel}>{label}</Text>
      <Text style={[styles.statusDetail, { color: ok === null ? faint : ok ? pen : '#FF6B5E' }]} numberOfLines={1}>
        {detail}
      </Text>
    </View>
  );
}

function Row({ label, value, onChange, pen }: { label: string; value: boolean; onChange: (v: boolean) => void; pen: string }) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowText}>{label}</Text>
      <Switch
        value={value}
        onValueChange={onChange}
        trackColor={{ true: pen, false: 'rgba(255,255,255,0.15)' }}
        thumbColor={paper}
        ios_backgroundColor="rgba(255,255,255,0.15)"
        // react-native-web colours the "on" thumb separately.
        {...({ activeThumbColor: paper } as object)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  scrim: { backgroundColor: 'rgba(0,0,0,0.45)' },
  sheetPos: { position: 'absolute', left: 8, right: 8, bottom: 8 },
  tint: { backgroundColor: glassStrong },
  sheet: {
    overflow: 'hidden',
    borderRadius: 32,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    paddingHorizontal: 20,
    paddingTop: 10,
  },
  scroll: { flexGrow: 0 },
  // The handle and title: drag here to put the sheet away.
  head: { marginTop: -10, paddingTop: 10 },
  grab: { alignSelf: 'center', width: 36, height: 4, borderRadius: 2, backgroundColor: 'rgba(255,255,255,0.2)', marginBottom: 12 },
  h1: { color: paper, ...face.bold, fontSize: 34, letterSpacing: -0.4, marginBottom: 6 },
  section: { color: faint, ...face.semibold, fontSize: 13, marginTop: 20, marginBottom: 8 },
  segment: { flexDirection: 'row', gap: 4, padding: 4, borderRadius: 18, backgroundColor: 'rgba(255,255,255,0.06)' },
  segItem: { height: 38, borderRadius: 14, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 },
  segText: { color: paper, ...face.semibold, fontSize: 13.5 },
  note: { color: mist, ...face.regular, fontSize: 14, marginTop: 8 },
  status: { marginTop: 12, gap: 8 },
  statusRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  statusLabel: { color: paper, ...face.semibold, fontSize: 14 },
  statusDetail: { flex: 1, textAlign: 'right', ...face.regular, fontSize: 14 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', height: 46 },
  rowText: { color: paper, ...face.regular, fontSize: 16 },
  danger: { height: 32, paddingHorizontal: 13, borderRadius: 16, justifyContent: 'center', backgroundColor: 'rgba(255,107,94,0.14)' },
  dangerText: { color: '#FF9C8F', ...face.semibold, fontSize: 14 },
  credits: { color: faint, ...face.regular, fontSize: 12.5, lineHeight: 17 },
  input: {
    height: 46,
    borderRadius: 14,
    paddingHorizontal: 14,
    backgroundColor: 'rgba(255,255,255,0.06)',
    color: paper,
    ...face.medium,
    fontSize: 13,
    outlineWidth: 0,
  },
});

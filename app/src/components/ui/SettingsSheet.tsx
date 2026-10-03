import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import Animated, { FadeIn, FadeOut, LinearTransition, SlideInDown, SlideOutDown } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LensiAR, type IntelligenceStatus } from '../../../modules/lensi-ar/src';
import { cloudEngine, serverURL } from '../../lib/engines/cloud';
import { setSettings, useSettings, type Brain } from '../../lib/settings';
import { PressScale } from '../../motion/PressScale';
import { faint, glassStrong, hairline, ink, mist, paper } from '../../theme/tokens';
import { fonts } from '../../theme/type';

const BRAINS: { key: Brain; name: string; note: string }[] = [
  { key: 'auto', name: 'Auto', note: 'On-device first, then the cloud, then eyes only.' },
  { key: 'apple', name: 'On-device', note: 'Apple Intelligence. Private, offline, free.' },
  { key: 'cloud', name: 'Claude', note: 'Sharper answers via your Lensi server.' },
  { key: 'vision', name: 'Eyes only', note: 'No model: outlines, text and codes found on the phone.' },
];

export function SettingsSheet({ pen, onClose }: { pen: string; onClose: () => void }) {
  const s = useSettings();
  const insets = useSafeAreaInsets();
  const [apple, setApple] = useState<IntelligenceStatus | null>(null);
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
      <Animated.View
        entering={SlideInDown.springify().damping(20).stiffness(190)}
        exiting={SlideOutDown.duration(220)}
        style={[styles.sheet, { paddingBottom: insets.bottom + 18 }]}
      >
        <View style={styles.grab} />
        <Text style={styles.h1}>Settings</Text>

        <Text style={styles.section}>BRAIN</Text>
        <View style={styles.segment}>
          {BRAINS.map((b) => {
            const on = s.brain === b.key;
            return (
              <PressScale key={b.key} onPress={() => setSettings({ brain: b.key })} scaleTo={0.94} haptic="selection" style={{ flex: 1 }} accessibilityRole="button" accessibilityLabel={b.name}>
                <Animated.View layout={LinearTransition.springify().damping(20)} style={[styles.segItem, on && { backgroundColor: pen }]}>
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
          <StatusLine label="APPLE INTELLIGENCE" ok={apple?.available ?? null} detail={apple ? (apple.available ? (apple.images ? 'Ready · sees images' : 'Ready · text only') : apple.reason) : 'Checking…'} pen={pen} />
          <StatusLine label="LENSI SERVER" ok={cloudOk} detail={cloudOk === null ? 'Checking…' : cloudOk ? serverURL() : `Not reachable at ${serverURL()}`} pen={pen} />
        </View>

        <Text style={styles.section}>BEHAVIOUR</Text>
        <Row label="Read steps aloud" value={s.narrate} onChange={(v) => setSettings({ narrate: v })} pen={pen} />
        <Row label="Live brackets on the camera" value={s.liveBrackets} onChange={(v) => setSettings({ liveBrackets: v })} pen={pen} />
        <Row label="Haptics" value={s.haptics} onChange={(v) => setSettings({ haptics: v })} pen={pen} />

        <Text style={styles.section}>SERVER URL</Text>
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

        <Text style={styles.section}>MADE WITH</Text>
        <Text style={styles.credits}>
          Apple Foundation Models · Vision · ARKit. MobileSAM (Apache-2.0) for part outlines, YOLO11n (AGPL-3.0) for
          live detection. Type: Bricolage Grotesque, Funnel Sans, Fragment Mono, Instrument Serif (OFL). Motion ideas
          from React Bits, rebuilt for React Native. Demo photos from the Segment Anything and OpenCV samples
          (Apache-2.0).
        </Text>
      </Animated.View>
    </View>
  );
}

function StatusLine({ label, ok, detail, pen }: { label: string; ok: boolean | null; detail: string; pen: string }) {
  return (
    <View style={styles.statusRow}>
      <View style={[styles.statusDot, { backgroundColor: ok === null ? faint : ok ? pen : '#FF6B5E' }]} />
      <Text style={styles.statusLabel}>{label}</Text>
      <Text style={styles.statusDetail} numberOfLines={1}>
        {detail}
      </Text>
    </View>
  );
}

function Row({ label, value, onChange, pen }: { label: string; value: boolean; onChange: (v: boolean) => void; pen: string }) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowText}>{label}</Text>
      <Switch value={value} onValueChange={onChange} trackColor={{ true: pen, false: 'rgba(244,241,234,0.15)' }} thumbColor={paper} ios_backgroundColor="rgba(244,241,234,0.15)" />
    </View>
  );
}

const styles = StyleSheet.create({
  scrim: { backgroundColor: 'rgba(0,0,0,0.45)' },
  sheet: {
    position: 'absolute',
    left: 8,
    right: 8,
    bottom: 8,
    borderRadius: 32,
    borderCurve: 'continuous',
    backgroundColor: glassStrong,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: hairline,
    paddingHorizontal: 20,
    paddingTop: 10,
  },
  grab: { alignSelf: 'center', width: 36, height: 4, borderRadius: 2, backgroundColor: 'rgba(244,241,234,0.2)', marginBottom: 12 },
  h1: { color: paper, fontFamily: fonts.serifItalic, fontSize: 38, letterSpacing: -0.6, marginBottom: 6 },
  section: { color: faint, fontFamily: fonts.mono, fontSize: 10.5, letterSpacing: 1.4, marginTop: 18, marginBottom: 8 },
  segment: { flexDirection: 'row', gap: 4, padding: 4, borderRadius: 18, backgroundColor: 'rgba(244,241,234,0.06)' },
  segItem: { height: 38, borderRadius: 14, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 },
  segText: { color: paper, fontFamily: fonts.textSemi, fontSize: 13.5 },
  note: { color: mist, fontFamily: fonts.text, fontSize: 14, marginTop: 8 },
  status: { marginTop: 12, gap: 8 },
  statusRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  statusDot: { width: 7, height: 7, borderRadius: 4 },
  statusLabel: { color: paper, fontFamily: fonts.mono, fontSize: 10.5, letterSpacing: 1.1 },
  statusDetail: { flex: 1, color: faint, fontFamily: fonts.mono, fontSize: 10.5, letterSpacing: 0.4 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', height: 46 },
  rowText: { color: paper, fontFamily: fonts.text, fontSize: 16 },
  credits: { color: faint, fontFamily: fonts.text, fontSize: 12.5, lineHeight: 17 },
  input: {
    height: 46,
    borderRadius: 14,
    paddingHorizontal: 14,
    backgroundColor: 'rgba(244,241,234,0.06)',
    color: paper,
    fontFamily: fonts.mono,
    fontSize: 13,
  },
});

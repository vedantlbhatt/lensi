import { LinearGradient } from 'expo-linear-gradient';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Platform, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { FadeIn, FadeOut, useAnimatedStyle, useSharedValue, withSpring, withTiming } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { isVirtual, type DemoScene, type TrackingEvent } from '../../modules/lensi-ar/src';
import { BrainChip } from '../components/camera/BrainChip';
import { CameraSurface, type CameraHandle } from '../components/camera/CameraSurface';
import { DropMenu, type DropChoice } from '../components/camera/DropMenu';
import { Flash, type FlashRef } from '../components/camera/Flash';
import { FocusLabel } from '../components/camera/FocusLabel';
import { LensCarousel } from '../components/camera/LensCarousel';
import { ListeningOverlay } from '../components/camera/ListeningOverlay';
import { MemoriesButton, MEMORIES_SIZE } from '../components/camera/MemoriesButton';
import { MicButton } from '../components/camera/MicButton';
import { Shutter } from '../components/camera/Shutter';
import { ToolRail } from '../components/camera/ToolRail';
import { CaptureView, type Rect } from '../components/capture/CaptureView';
import { MemoriesSheet } from '../components/memories/MemoriesSheet';
import { SettingsSheet } from '../components/ui/SettingsSheet';
import { toast, ToastHost } from '../components/ui/Toast';
import { pickEngine } from '../lib/engines';
import { useLivePins } from '../lib/live';
import { pasteFromClipboard, pickFromFiles, pickFromLibrary, type Picked } from '../lib/media';
import { ingest } from '../lib/pipeline';
import { useSettings } from '../lib/settings';
import { useCaptureList } from '../lib/store';
import type { EngineId } from '../lib/types';
import { useVoice } from '../lib/voice';
import { Sparks, type SparksRef } from '../motion/Sparks';
import { springs } from '../theme/motion';
import { LENSES, lensInfo, type Lens } from '../theme/tokens';
import { fonts } from '../theme/type';

const TRACKING_HINTS: Record<string, string> = {
  initializing: 'Move your phone slowly',
  excessiveMotion: 'Slow down a little',
  insufficientFeatures: 'Point at something with more detail',
  relocalizing: 'Finding your place again',
};

type Open = { id: string; origin: 'camera' | Rect };

/**
 * The app opens here: the camera, edge to edge. Tap the shutter for a photo,
 * hold it for video, hold the mic to ask out loud, drop anything in from the
 * rail, swipe up for Memories.
 */
export default function Camera() {
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  const settings = useSettings();
  const captures = useCaptureList();

  const camera = useRef<CameraHandle>(null);
  const flash = useRef<FlashRef>(null);
  const sparks = useRef<SparksRef>(null);

  const [lens, setLens] = useState<Lens>('identify');
  const [live, setLive] = useState(false);
  const [torch, setTorch] = useState(false);
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState<Open | null>(null);
  const [memories, setMemories] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [drop, setDrop] = useState(false);
  const [focus, setFocus] = useState<string | null>(null);
  const [scene, setScene] = useState<DemoScene | null>(null);
  const [tracking, setTracking] = useState<TrackingEvent | null>(null);
  const [engine, setEngine] = useState<EngineId | null>(null);

  const pen = lensInfo(lens).pen;
  const voice = useVoice();
  const livePins = useLivePins(camera, lens);

  useEffect(() => {
    let alive = true;
    pickEngine(settings.brain).then((e) => alive && setEngine(e.id));
    return () => {
      alive = false;
    };
  }, [settings.brain, settings.serverURL]);

  useEffect(() => {
    if (voice.error) toast(voice.error);
  }, [voice.error]);

  // Where captures fly when they're filed away.
  const memoriesRect: Rect = {
    x: 26,
    y: height - insets.bottom - 18 - (84 + 40) / 2 - MEMORIES_SIZE / 2,
    w: MEMORIES_SIZE,
    h: MEMORIES_SIZE,
  };

  const openPicked = useCallback(
    async (picked: Picked | null, origin: Open['origin'], prompt?: string) => {
      if (!picked) return;
      const id = await ingest(picked, { lens, prompt: prompt ?? null });
      setOpen({ id, origin });
    },
    [lens],
  );

  const takePhoto = useCallback(
    async (prompt?: string) => {
      if (busy) return;
      setBusy(true);
      flash.current?.fire();
      try {
        const p = await camera.current?.takePhoto();
        if (!p) {
          toast("Couldn't take that photo");
          return;
        }
        await openPicked(prompt ? { ...p, source: 'voice' } : p, 'camera', prompt);
      } catch (e) {
        console.warn('[lensi] photo failed', e);
        toast("Couldn't take that photo");
      } finally {
        setBusy(false);
      }
    },
    [busy, openPicked],
  );

  const recordStart = useCallback(async () => {
    const ok = (await camera.current?.startRecording()) ?? false;
    if (!ok) toast(isVirtual ? 'Video needs the iPhone camera' : "Couldn't start recording");
    return ok;
  }, []);

  const recordStop = useCallback(async () => {
    setBusy(true);
    try {
      const v = await camera.current?.stopRecording();
      if (v) await openPicked(v, 'camera');
    } finally {
      setBusy(false);
    }
  }, [openPicked]);

  const onDrop = useCallback(
    async (c: DropChoice) => {
      setDrop(false);
      try {
        const picked = c === 'library' ? await pickFromLibrary() : c === 'files' ? await pickFromFiles() : await pasteFromClipboard();
        if (!picked) {
          if (c === 'paste') toast('Nothing image-like on the clipboard');
          return;
        }
        await openPicked(picked, { x: width - 60, y: insets.top + 110, w: 40, h: 40 });
      } catch (e) {
        console.warn('[lensi] import failed', e);
        toast("Couldn't open that");
      }
    },
    [openPicked, width, insets.top],
  );

  const onMicStart = useCallback(() => {
    void voice.start();
  }, [voice]);
  const onMicEnd = useCallback(async () => {
    if (!voice.listening) return;
    const q = await voice.stop();
    if (!q) {
      toast("Didn't catch that. Hold the mic while you talk.");
      return;
    }
    await takePhoto(q);
  }, [voice, takePhoto]);

  // Swipe up anywhere for Memories; sideways to change lens (real camera only,
  // the virtual one uses sideways swipes for scenes).
  const swipe = Gesture.Pan()
    .runOnJS(true)
    .minDistance(30)
    .onEnd((e) => {
      if (e.translationY < -80 && Math.abs(e.translationY) > Math.abs(e.translationX)) setMemories(true);
      else if (!isVirtual && Math.abs(e.translationX) > 70) {
        const i = LENSES.findIndex((l) => l.key === lens);
        const next = LENSES[Math.max(0, Math.min(LENSES.length - 1, i + (e.translationX < 0 ? 1 : -1)))];
        setLens(next.key);
      }
    });
  const tapToPin = Gesture.Tap()
    .runOnJS(true)
    .onEnd((e) => {
      if (live) sparks.current?.burst(e.absoluteX, e.absoluteY, pen);
    });

  const chrome = useSharedValue(1);
  useEffect(() => {
    chrome.value = withTiming(open || memories ? 0 : voice.listening ? 0.35 : 1, { duration: 220 });
  }, [open, memories, voice.listening, chrome]);
  const chromeStyle = useAnimatedStyle(() => ({ opacity: chrome.value }));
  const lift = useSharedValue(0);
  useEffect(() => {
    lift.value = withSpring(voice.listening ? 1 : 0, springs.arrive);
  }, [voice.listening, lift]);
  const bottomStyle = useAnimatedStyle(() => ({ transform: [{ translateY: lift.value * 8 }] }));

  const hint = tracking?.state === 'limited' ? TRACKING_HINTS[tracking.reason] : null;
  const focusText = isVirtual ? (scene?.caption ?? null) : live ? (focus ? `tap to pin · ${focus}` : 'tap anything to pin it') : focus;
  const latest = captures[0];

  return (
    <View style={styles.root}>
      <GestureDetector gesture={Gesture.Simultaneous(swipe, tapToPin)}>
        <View style={StyleSheet.absoluteFill} collapsable={false}>
          <CameraSurface
            ref={camera}
            pen={pen}
            brackets={settings.liveBrackets}
            livePins={live}
            paused={!!open || memories}
            onFocusChange={setFocus}
            onTracking={setTracking}
            onSelect={livePins.onSelect}
            onPinTap={livePins.onPinTap}
            onScene={setScene}
          />
        </View>
      </GestureDetector>

      {/* Legibility: soft shade behind top and bottom chrome. */}
      <LinearGradient colors={['rgba(11,11,12,0.45)', 'rgba(11,11,12,0)']} style={[styles.shade, { top: 0, height: insets.top + 120 }]} pointerEvents="none" />
      <LinearGradient colors={['rgba(11,11,12,0)', 'rgba(11,11,12,0.55)']} style={[styles.shade, { bottom: 0, height: 280 }]} pointerEvents="none" />

      <Animated.View style={[StyleSheet.absoluteFill, chromeStyle]} pointerEvents={open || memories ? 'none' : 'box-none'}>
        <View style={[styles.top, { top: insets.top + 8 }]} pointerEvents="box-none">
          <BrainChip engine={engine} pen={pen} onPress={() => setSettingsOpen(true)} />
          <ToolRail
            torch={torch}
            live={live}
            pen={pen}
            onTorch={async () => {
              const want = !torch;
              const ok = await camera.current?.setTorch(want);
              if (!ok && want) toast(isVirtual ? 'No torch on the virtual camera' : 'Torch unavailable');
              setTorch(!!ok && want);
            }}
            onLive={() => {
              setLive((v) => !v);
              toast(live ? 'Live pins off' : 'Live pins: tap things to pin them in space');
            }}
            onDrop={() => setDrop(true)}
            onSettings={() => setSettingsOpen(true)}
          />
        </View>

        {hint && !isVirtual ? (
          <Animated.View entering={FadeIn} exiting={FadeOut} style={[styles.hintWrap, { top: insets.top + 60 }]} pointerEvents="none">
            <Text style={styles.hint}>{hint}</Text>
          </Animated.View>
        ) : null}

        <Animated.View style={[styles.bottom, { paddingBottom: insets.bottom + 18 }, bottomStyle]} pointerEvents="box-none">
          <FocusLabel label={focusText} tag={isVirtual ? (Platform.OS === 'web' ? 'PREVIEW' : 'SIM') : live ? 'LIVE' : null} pen={pen} />
          <LensCarousel lens={lens} onChange={setLens} />
          <View style={styles.row}>
            <MemoriesButton uri={latest?.media.stillUri ?? null} count={captures.length} onPress={() => setMemories(true)} />
            <Shutter pen={pen} disabled={busy} onPhoto={() => void takePhoto()} onRecordStart={recordStart} onRecordStop={() => void recordStop()} />
            <MicButton pen={pen} listening={voice.listening} level={voice.level} onHoldStart={onMicStart} onHoldEnd={() => void onMicEnd()} onTap={() => toast('Hold the mic and ask out loud')} />
          </View>
        </Animated.View>
      </Animated.View>

      {voice.listening ? <ListeningOverlay transcript={voice.transcript} pen={pen} top={insets.top + 120} /> : null}

      <Sparks ref={sparks} />
      <Flash ref={flash} />

      {drop ? <DropMenu top={insets.top + 64} onPick={(c) => void onDrop(c)} onClose={() => setDrop(false)} /> : null}

      {memories ? (
        <MemoriesSheet
          onOpen={(id, from) => {
            setOpen({ id, origin: from });
          }}
          onClose={() => setMemories(false)}
        />
      ) : null}

      {open ? <CaptureView key={open.id} id={open.id} origin={open.origin} dismissTo={memoriesRect} onClosed={() => setOpen(null)} /> : null}

      {settingsOpen ? <SettingsSheet pen={pen} onClose={() => setSettingsOpen(false)} /> : null}
      <ToastHost />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  shade: { position: 'absolute', left: 0, right: 0 },
  top: { position: 'absolute', left: 14, right: 14, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start' },
  hintWrap: { position: 'absolute', alignSelf: 'center', paddingHorizontal: 14, height: 32, borderRadius: 16, justifyContent: 'center', backgroundColor: 'rgba(11,11,12,0.7)' },
  hint: { color: '#F4F1EA', fontFamily: fonts.textSemi, fontSize: 14 },
  bottom: { position: 'absolute', left: 0, right: 0, bottom: 0, alignItems: 'center', gap: 6 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', alignSelf: 'stretch', paddingHorizontal: 26 },
});

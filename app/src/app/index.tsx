import { Asset } from 'expo-asset';
import { File, Paths } from 'expo-file-system';
import { LinearGradient } from 'expo-linear-gradient';
import { useGlobalSearchParams } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, Platform, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { FadeIn, FadeOut, useAnimatedStyle, useSharedValue, withSpring, withTiming } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DEMO_SCENES, isVirtual, LensiAR, setDemoTalk, setSceneTracks, type DemoScene, type TrackingEvent } from '../../modules/lensi-ar/src';
import { BrainChip } from '../components/camera/BrainChip';
import { CameraBlocked } from '../components/camera/CameraBlocked';
import { CameraSurface, type CameraHandle } from '../components/camera/CameraSurface';
import { CoachMark } from '../components/camera/CoachMark';
import { DropMenu, type DropChoice } from '../components/camera/DropMenu';
import { Flash, type FlashRef } from '../components/camera/Flash';
import { FocusLabel } from '../components/camera/FocusLabel';
import { GuidePanel } from '../components/guide/GuidePanel';
import { LensCarousel } from '../components/camera/LensCarousel';
import { ListeningOverlay } from '../components/camera/ListeningOverlay';
import { MemoriesButton, MEMORIES_SIZE } from '../components/camera/MemoriesButton';
import { MicButton } from '../components/camera/MicButton';
import { ScrubStrip } from '../components/camera/ScrubStrip';
import { Shutter } from '../components/camera/Shutter';
import { ToolRail } from '../components/camera/ToolRail';
import { outlineAt } from '../components/camera/VirtualCamera';
import { ZoomDial } from '../components/camera/ZoomDial';
import { CaptureView, type Rect } from '../components/capture/CaptureView';
import { MemoriesSheet } from '../components/memories/MemoriesSheet';
import { SettingsSheet } from '../components/ui/SettingsSheet';
import { toast, ToastHost } from '../components/ui/Toast';
import { devhooks } from '../lib/devhooks';
import { pickEngine } from '../lib/engines';
import { heard } from '../lib/guide';
import { useGuide } from '../lib/guideSession';
import { useHandsFree } from '../lib/handsFree';
import { useLivePins } from '../lib/live';
import { assetPhoto, pasteFromClipboard, pickedFromFile, pickFromFiles, pickFromLibrary, type Picked } from '../lib/media';
import { pointOf, queryOf, type ScriptParams } from '../lib/links';
import { ingest } from '../lib/pipeline';
import { getSettings, setSettings, useSettings } from '../lib/settings';
import { useCaptureList } from '../lib/store';
import type { EngineId } from '../lib/types';
import { hush } from '../lib/narrate';
import { applyUpdate, applyWhenAway, checkForUpdate, confirmLaunch, forceOTA, otaEnabled, RUNNING_UPDATE } from '../lib/ota';
import { useVoice } from '../lib/voice';
import { springs } from '../theme/motion';
import { LENSES, lensInfo, type Lens } from '../theme/tokens';
import { face } from '../theme/type';

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

  // Every launch opens on the live guide: open the app, point, say the job.
  const [lens, setLens] = useState<Lens>('guide');
  const [torch, setTorch] = useState(false);
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState<Open | null>(null);
  const [memories, setMemories] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [drop, setDrop] = useState(false);
  const [scene, setScene] = useState<DemoScene | null>(null);
  // What's pinned from the strip (the camera keeps the pins themselves).
  const [pinIds, setPinIds] = useState<string[]>([]);
  const [tracking, setTracking] = useState<TrackingEvent | null>(null);
  // The camera never started (no permission, sensor error): say so, keep Drop working.
  const blocked = tracking?.state === 'failed' ? (tracking.reason === 'cameraDenied' ? 'cameraDenied' : 'failed') : null;
  const blockedRef = useRef(blocked);
  blockedRef.current = blocked;
  const [camKey, setCamKey] = useState(0);
  const retryCamera = useCallback(() => {
    setTracking(null);
    setCamKey((k) => k + 1);
  }, []);
  // Coming back from Settings with the camera allowed: start it again.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) => {
      if (s === 'active' && blockedRef.current) retryCamera();
    });
    return () => sub.remove();
  }, [retryCamera]);
  const [engine, setEngine] = useState<EngineId | null>(null);
  const [touched, setTouched] = useState(false);
  // Where the guide panel starts, so tags whose part is out of view wait above it.
  const [panelTop, setPanelTop] = useState(0);

  const pen = lensInfo(lens).pen;
  const voice = useVoice();
  const livePins = useLivePins(camera, lens);

  // The live guide is the Guide lens: tags pinned on the parts, one step at a time.
  const guideLens = lens === 'guide';
  const guideOn = guideLens && !open && !memories && !blocked;
  const guide = useGuide(camera, { enabled: guideOn });
  const guideHandle = guide.handle;
  // Leaving the Guide lens ends the job; a capture or Memories on top only pauses it.
  useEffect(() => {
    if (!guideLens) guide.stop();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [guideLens]);
  // A different virtual scene: the tags belonged to the last one.
  const guideStop = guide.stop;
  const lastScene = useRef<string | null>(null);
  const onScene = useCallback(
    (s: DemoScene) => {
      setScene(s);
      if (lastScene.current && lastScene.current !== s.key) {
        guideStop();
        // The virtual camera's pins were on the last scene.
        setPinIds([]);
      }
      lastScene.current = s.key;
    },
    [guideStop],
  );
  // Hands are busy: tap to talk, and a pause sends it. Once they've talked,
  // the mic keeps opening between the app's lines (hands free) while a step is
  // up, until the job is done or they tap it off.
  const guideStatus = guide.state.status;
  const handsFree = useHandsFree(voice, guideOn && (guideStatus === 'active' || guideStatus === 'checking' || guideStatus === 'answering'));
  const setHandsFree = handsFree.setOn;
  const freeRef = useRef(false);
  freeRef.current = handsFree.on;
  const onHeard = useCallback(
    (q: string, free: boolean) => {
      // Half a line that was still being heard when hands free was switched off.
      if (free && !freeRef.current) return;
      const cmd = heard(q, free);
      if (!cmd) return;
      if (cmd.type === 'mute') {
        setHandsFree(false);
        return;
      }
      guideHandle(cmd);
      if (!free && cmd.type !== 'stop' && getSettings().handsFree) setHandsFree(true);
    },
    [guideHandle, setHandsFree],
  );
  const guideMic = useCallback(async () => {
    if (freeRef.current) {
      // Hands free already: a tap turns it off, and lets go of anything half heard.
      setHandsFree(false);
      return;
    }
    if (voice.isListening()) {
      const q = await voice.stop();
      if (q) onHeard(q, false);
      return;
    }
    hush();
    setTouched(true);
    await voice.start();
  }, [voice, onHeard, setHandsFree]);
  // A pause sends it: soon after a short command, a beat later after anything else.
  const stopVoice = voice.stop;
  useEffect(() => {
    if (!guideOn || !voice.listening || !voice.transcript) return;
    const quick = heard(voice.transcript, false)?.type !== 'ask';
    const free = freeRef.current;
    const t = setTimeout(() => {
      void stopVoice().then((q) => q && onHeard(q, free));
    }, quick ? 900 : 1500);
    return () => clearTimeout(t);
  }, [guideOn, voice.listening, voice.transcript, stopVoice, onHeard]);
  // A mic left open: after 15 s, use whatever was heard. Hands free waits
  // longer before starting a fresh session (each one is a recognition request).
  useEffect(() => {
    if (!guideOn || !voice.listening) return;
    const free = freeRef.current;
    const t = setTimeout(
      () => {
        void stopVoice().then((q) => q && onHeard(q, free));
      },
      free ? 45000 : 15000,
    );
    return () => clearTimeout(t);
  }, [guideOn, voice.listening, stopVoice, onHeard]);
  // Hands free ends with the job.
  useEffect(() => {
    if (guideStatus === 'idle' || guideStatus === 'finished') setHandsFree(false);
  }, [guideStatus, setHandsFree]);

  // Re-checked whenever the camera is back in front: a model that just failed
  // is resting, a server may have come up.
  const cameraFront = !open;
  useEffect(() => {
    if (!cameraFront) return;
    let alive = true;
    pickEngine(settings.brain).then((e) => {
      if (!alive) return;
      setEngine(e.id);
      // Load Apple's model now, so the first question doesn't wait for it.
      if (e.id === 'apple') void LensiAR.intelligencePrewarm().catch(() => {});
    });
    return () => {
      alive = false;
    };
  }, [settings.brain, settings.serverURL, cameraFront]);

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
      setTouched(true);
      const id = await ingest(picked, { lens, prompt: prompt ?? null });
      setOpen({ id, origin });
    },
    [lens],
  );

  const takePhoto = useCallback(
    async (prompt?: string) => {
      if (busy) return;
      if (blockedRef.current) {
        toast('The camera is off. Drop in a photo instead.');
        setDrop(true);
        return;
      }
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
    try {
      const ok = (await camera.current?.startRecording()) ?? false;
      if (!ok) toast(isVirtual ? 'Video needs the iPhone camera' : "Couldn't start recording");
      return ok;
    } catch (e) {
      toast(e instanceof Error ? e.message : "Couldn't start recording");
      return false;
    }
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
    const wasListening = voice.isListening();
    // Always stop: it also cancels a start still waiting on a permission alert.
    const q = await voice.stop();
    if (!wasListening) return;
    if (!q) {
      toast("Didn't catch that. Hold the mic while you talk.");
      return;
    }
    await takePhoto(q);
  }, [voice, takePhoto]);

  // Scripted runs (CI screenshots, the web preview): lensi:///?demo=cars&lens=guide&ask=…
  // A deep link wins; otherwise the URL the launch environment carried (CI).
  const linked = useGlobalSearchParams<ScriptParams>();
  const launched = useMemo(() => queryOf(LensiAR.launchURL), []);
  const params: ScriptParams = linked.demo || linked.memories || linked.file || linked.guide || linked.scene ? linked : launched;
  useEffect(() => {
    if (params.export) devhooks.autoExport = true;
    if (params.ota) {
      forceOTA();
      // Once restarted into an update, say which (CI's screenshot and log show it).
      if (RUNNING_UPDATE !== 'dev') {
        console.log(`[lensi] running update ${RUNNING_UPDATE}`);
        setTimeout(() => toast(`Running update ${RUNNING_UPDATE.slice(0, 7)}`), 1500);
      }
    }
    if (params.tap) devhooks.autoTap = pointOf(params.tap);
    if (params.moment && /^\d+$/.test(params.moment)) devhooks.autoMoment = Number(params.moment);
    if (params.memories) setMemories(true);
    if (params.talk) setDemoTalk(params.talk.split('|'));
    if (params.brain === 'auto' || params.brain === 'apple' || params.brain === 'cloud' || params.brain === 'vision') {
      setSettings({ brain: params.brain });
    }
    if (params.guide) {
      // Give the camera a moment to come up, then start the job as if it were said.
      setLens('guide');
      const task = params.guide;
      const h = setTimeout(() => guideHandle(task), 2200);
      return () => clearTimeout(h);
    }
    const scene = DEMO_SCENES.find((s) => s.key === params.demo);
    const file = Platform.OS !== 'web' && params.file ? new File(Paths.document, params.file) : null;
    if (!scene && !file) return;
    const l = LENSES.find((x) => x.key === params.lens)?.key ?? 'identify';
    setLens(l);
    let alive = true;
    (async () => {
      let picked: Picked;
      if (file) {
        if (!file.exists) {
          toast(`No ${params.file} in Documents`);
          return;
        }
        picked = await pickedFromFile(file.uri, file.name, undefined, 'files');
      } else {
        picked = await assetPhoto(scene!.asset, scene!.width, scene!.height);
      }
      if (!alive) return;
      flash.current?.fire();
      const id = await ingest(params.ask ? { ...picked, source: 'voice' } : picked, { lens: l, prompt: params.ask ?? null });
      if (alive) setOpen({ id, origin: 'camera' });
    })();
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [params.demo, params.file, params.lens, params.ask, params.memories, params.export, params.brain, params.tap, params.moment, params.guide, params.talk]);

  // Scripted: the app's EdgeTAM on a demo clip (?edgetam=shaker), with the models it ships, pinned
  // on the clip's tracked thing as it is in the first frame and followed through every frame, as
  // the phone follows a pinned thing. The virtual camera then shows what it found in place of the
  // bundled tracks, and it's left in Documents for CI: lensi-edgetam.json, and the clip drawn with
  // it as the phone draws it (lensi-edgetam.mp4, written by the app).
  useEffect(() => {
    if (!params.edgetam || Platform.OS === 'web') return;
    const scene = DEMO_SCENES.find((s) => s.key === params.edgetam);
    const tracks = scene?.video?.tracks;
    const first = tracks ? outlineAt(tracks, 0, 0) : null;
    if (!scene?.video || !first) return;
    const xs = first.map((p) => p.x);
    const ys = first.map((p) => p.y);
    const box: [number, number, number, number] = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
    const source = scene.video.source;
    let alive = true;
    void (async () => {
      try {
        const asset = Asset.fromModule(source);
        await asset.downloadAsync();
        const film = new File(Paths.document, 'lensi-edgetam.mp4');
        const run = await LensiAR.trackVideo(asset.localUri ?? asset.uri, box, 1, film.uri, pen);
        setSceneTracks(scene.key, run.tracks);
        new File(Paths.document, 'lensi-edgetam.json').write(JSON.stringify(run));
        console.log(`[lensi] EdgeTAM followed it in ${run.seen} of ${run.count} frames, ${Math.round(run.medianMs)} ms a frame`);
        if (alive) toast(`EdgeTAM followed it in ${run.seen} of ${run.count} frames`);
      } catch (e) {
        devhooks.report('edgetam', e);
      }
    })();
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [params.edgetam]);

  // Scripted strip and dial (CI and the web demo film them): ?zoom=2.7 turns the dial there
  // and leaves it up; ?scrub=0.2,0.6 lands a finger on the strip, slides and holds (a pin).
  const [dialDemo, setDialDemo] = useState<number | undefined>();
  const [stripDemo, setStripDemo] = useState<number[] | undefined>();
  useEffect(() => {
    const timers: ReturnType<typeof setTimeout>[] = [];
    const z = Number(params.zoom);
    if (params.zoom && Number.isFinite(z)) timers.push(setTimeout(() => setDialDemo(z), 2000));
    const stops = (params.scrub ?? '').split(',').map(Number).filter((v) => Number.isFinite(v) && v >= 0 && v <= 1);
    if (params.scrub && stops.length) timers.push(setTimeout(() => setStripDemo(stops), params.zoom ? 5500 : 2500));
    return () => timers.forEach(clearTimeout);
  }, [params.scrub, params.zoom]);

  // Zoom: the dial at the bottom (drag across it, or tap it for the next stop), or a pinch on
  // the camera. The camera says how far it goes (.5 only where ARKit can track with the
  // ultra-wide); the dial keeps whatever zoom it's let go at.
  const [zoomRange, setZoomRange] = useState({ min: 1, max: 10 });
  const [zoomShown, setZoomShown] = useState(1);
  const zoomLive = useSharedValue(1);
  const [pinching, setPinching] = useState(false);
  const pinchFrom = useRef(1);
  const zoomTo = useCallback(
    (z: number) => {
      const v = Math.min(zoomRange.max, Math.max(zoomRange.min, z));
      zoomLive.value = v;
      camera.current?.setZoom(v);
      // The label only needs tenths, so most frames of a drag don't re-render.
      setZoomShown(Math.round(v * 10) / 10);
    },
    [zoomRange, zoomLive],
  );
  const onZoomRange = useCallback((r: { min: number; max: number }) => setZoomRange({ min: r.min, max: r.max }), []);
  const pinch = Gesture.Pinch()
    .runOnJS(true)
    .onBegin(() => {
      pinchFrom.current = zoomLive.value;
    })
    .onStart(() => setPinching(true))
    .onUpdate((e) => zoomTo(pinchFrom.current * e.scale))
    .onFinalize(() => setPinching(false));

  // The strip: slide along it to pick one of the things in view, hold still to pin it. The
  // things are found where the finger lands, in the part of the screen the chrome leaves.
  // While a finger is on it the zoom button steps aside; while the dial is up, what's under it does.
  const [scrubbing, setScrubbing] = useState(false);
  const [dialOpen, setDialOpen] = useState(false);
  const stripStart = useCallback(
    (top: number) => {
      setTouched(true);
      setScrubbing(true);
      const bottom = Number.isFinite(top) && top > 0 ? top - 4 : panelTop || height - 300;
      return camera.current?.scrub.start(insets.top + 56, bottom) ?? Promise.resolve([]);
    },
    [insets.top, panelTop, height],
  );
  const stripMove = useCallback((i: number) => camera.current?.scrub.to(i), []);
  const stripPin = useCallback(async (i: number) => {
    const id = await camera.current?.scrub.pin(i);
    if (id) setPinIds((ids) => (ids.includes(id) ? ids : [...ids, id]));
  }, []);
  const stripEnd = useCallback(() => {
    setScrubbing(false);
    camera.current?.scrub.end();
  }, []);
  const stripClear = useCallback(() => {
    camera.current?.scrub.clear();
    setPinIds([]);
  }, []);

  // Over the air (src/lib/ota.ts): newer JavaScript for this build is fetched at launch. It
  // restarts into it straight away when nothing is in hand, else the next time the app goes
  // to the background.
  const otaIdle = !open && !memories && guideStatus === 'idle' && !scrubbing && !voice.listening;
  const otaIdleRef = useRef(otaIdle);
  otaIdleRef.current = otaIdle;
  useEffect(() => {
    // Whatever JavaScript this is, it got going: an update it started from stays.
    const confirm = setTimeout(confirmLaunch, 3000);
    if (!otaEnabled()) return () => clearTimeout(confirm);
    let alive = true;
    const check = setTimeout(() => {
      checkForUpdate()
        .then((u) => {
          if (!alive || !u) return;
          if (otaIdleRef.current) {
            toast('Updating Lensi');
            setTimeout(applyUpdate, 900);
          } else {
            toast('Lensi updated. It restarts next time you leave the app.');
            applyWhenAway();
          }
        })
        .catch((e) => console.warn('[lensi] update check failed', e));
    }, 4000);
    return () => {
      alive = false;
      clearTimeout(confirm);
      clearTimeout(check);
    };
  }, []);

  // Swipe up anywhere for Memories; sideways changes the lens on a real camera
  // and the demo scene on the virtual one. One finger: two are a pinch.
  const swipe = Gesture.Pan()
    .runOnJS(true)
    .maxPointers(1)
    .minDistance(30)
    .onEnd((e) => {
      if (e.translationY < -80 && Math.abs(e.translationY) > Math.abs(e.translationX)) setMemories(true);
      else if (isVirtual && Math.abs(e.translationX) > 60) camera.current?.nextScene?.(e.translationX < 0 ? 1 : -1);
      else if (!isVirtual && Math.abs(e.translationX) > 70) {
        const i = LENSES.findIndex((l) => l.key === lens);
        const next = LENSES[Math.max(0, Math.min(LENSES.length - 1, i + (e.translationX < 0 ? 1 : -1)))];
        setLens(next.key);
      }
    });
  const chrome = useSharedValue(1);
  useEffect(() => {
    // The guide keeps its panel lit while listening: that's where the words appear.
    chrome.value = withTiming(open || memories ? 0 : voice.listening && !guideLens ? 0.35 : 1, { duration: 220 });
  }, [open, memories, voice.listening, guideLens, chrome]);
  const chromeStyle = useAnimatedStyle(() => ({ opacity: chrome.value }));
  const lift = useSharedValue(0);
  useEffect(() => {
    lift.value = withSpring(voice.listening ? 1 : 0, springs.arrive);
  }, [voice.listening, lift]);
  const bottomStyle = useAnimatedStyle(() => ({ transform: [{ translateY: lift.value * 8 }] }));

  const hint = tracking?.state === 'limited' ? TRACKING_HINTS[tracking.reason] : null;
  // Only the virtual camera's scene caption: nothing on screen names what the camera happens to
  // be pointed at (it would change every time the phone moved). Pinned things carry their names.
  const focusText = isVirtual ? (scene?.caption ?? null) : null;
  const zoomDial = (
    <ZoomDial
      value={zoomLive}
      zoom={zoomShown}
      min={zoomRange.min}
      max={zoomRange.max}
      pen={pen}
      onZoom={zoomTo}
      turning={pinching}
      demo={dialDemo}
      onOpen={setDialOpen}
      hidden={scrubbing}
    />
  );
  const scrubStrip = (
    <ScrubStrip
      pen={pen}
      pins={pinIds.length}
      onStart={stripStart}
      onMove={stripMove}
      onPin={stripPin}
      onEnd={stripEnd}
      onClear={stripClear}
      demo={stripDemo}
    />
  );
  const latest = captures[0];

  return (
    <View style={styles.root}>
      <GestureDetector gesture={Gesture.Simultaneous(swipe, pinch)}>
        <View style={StyleSheet.absoluteFill} collapsable={false}>
          <CameraSurface
            key={camKey}
            ref={camera}
            pen={pen}
            brackets={settings.liveBrackets}
            liveOutlines={settings.liveBrackets}
            livePins={false}
            paused={!!open || memories}
            onTracking={setTracking}
            onSelect={livePins.onSelect}
            onPinTap={(id) => {
              const p = guide.state.parts.find((x) => x.id === id);
              if (p) toast(p.label);
              else livePins.onPinTap(id);
            }}
            onScene={onScene}
            onGuideChange={guide.onChange}
            onZoomRange={onZoomRange}
            guidePins={guideLens ? { parts: guide.state.parts, focus: guide.part?.id ?? null } : undefined}
            pinInsets={guideLens && panelTop ? { top: insets.top + 56, bottom: Math.max(0, height - panelTop + 8) } : undefined}
            sceneKey={params.scene}
          />
        </View>
      </GestureDetector>

      {/* Legibility: soft shade behind top and bottom chrome. */}
      <LinearGradient colors={['rgba(11,11,12,0.45)', 'rgba(11,11,12,0)']} style={[styles.shade, { top: 0, height: insets.top + 120 }]} pointerEvents="none" />
      <LinearGradient colors={['rgba(11,11,12,0)', 'rgba(11,11,12,0.55)']} style={[styles.shade, { bottom: 0, height: 280 }]} pointerEvents="none" />

      {blocked ? <CameraBlocked reason={blocked} pen={pen} onDrop={() => setDrop(true)} onRetry={retryCamera} /> : null}

      <Animated.View style={[StyleSheet.absoluteFill, chromeStyle]} pointerEvents={open || memories ? 'none' : 'box-none'}>
        <View style={[styles.top, { top: insets.top + 8 }]} pointerEvents="box-none">
          <BrainChip engine={engine} pen={pen} onPress={() => setSettingsOpen(true)} />
          <ToolRail
            torch={torch}
            pen={pen}
            onTorch={async () => {
              const want = !torch;
              const ok = await camera.current?.setTorch(want);
              if (!ok && want) toast(isVirtual ? 'No torch on the virtual camera' : 'Torch unavailable');
              setTorch(!!ok && want);
            }}
            onDrop={() => setDrop(true)}
            onSettings={() => setSettingsOpen(true)}
          />
        </View>

        {!guideLens && !touched && captures.length === 0 && !voice.listening && !blocked ? <CoachMark pen={pen} top={height * 0.36} /> : null}

        {hint && !isVirtual ? (
          <Animated.View entering={FadeIn} exiting={FadeOut} style={[styles.hintWrap, { top: insets.top + 60 }]} pointerEvents="none">
            <Text style={styles.hint}>{hint}</Text>
          </Animated.View>
        ) : null}

        {guideLens ? (
          <View
            style={[styles.bottom, { paddingBottom: insets.bottom + 10 }]}
            pointerEvents="box-none"
            onLayout={(e) => setPanelTop(Math.round(e.nativeEvent.layout.y))}
          >
            {guideStatus === 'idle' && !voice.listening ? (
              <View style={[styles.stack, dialOpen && styles.under]} pointerEvents={dialOpen ? 'none' : 'box-none'}>
                <FocusLabel label={focusText} tag={isVirtual ? (Platform.OS === 'web' ? 'Preview' : 'Simulator') : null} pen={pen} />
                <LensCarousel lens={lens} onChange={setLens} />
              </View>
            ) : null}
            {zoomDial}
            {scrubStrip}
            <GuidePanel
              state={guide.state}
              step={guide.step}
              part={guide.part}
              watching={guide.watching}
              pen={pen}
              listening={voice.listening}
              handsFree={handsFree.on}
              transcript={voice.transcript}
              level={voice.level}
              onMic={() => void guideMic()}
              onSubmit={guideHandle}
              onNext={guide.next}
              onBack={guide.back}
              onCheck={() => void guide.check()}
              onRepeat={guide.repeat}
              onStop={guide.stop}
            />
          </View>
        ) : (
        <Animated.View
          style={[styles.bottom, { paddingBottom: insets.bottom + 18 }, bottomStyle]}
          pointerEvents="box-none"
          onLayout={(e) => setPanelTop(Math.round(e.nativeEvent.layout.y))}
        >
          <View style={[styles.stack, dialOpen && styles.under]} pointerEvents="none">
            <FocusLabel label={focusText} tag={isVirtual ? (Platform.OS === 'web' ? 'Preview' : 'Simulator') : null} pen={pen} />
          </View>
          {zoomDial}
          {scrubStrip}
          <LensCarousel lens={lens} onChange={setLens} />
          <View style={styles.row}>
            <MemoriesButton uri={latest?.media.stillUri ?? null} count={captures.length} onPress={() => setMemories(true)} />
            <Shutter pen={pen} disabled={busy} onPhoto={() => void takePhoto()} onRecordStart={recordStart} onRecordStop={() => void recordStop()} />
            <MicButton pen={pen} listening={voice.listening} level={voice.level} onHoldStart={onMicStart} onHoldEnd={() => void onMicEnd()} onTap={() => toast('Hold the mic and ask out loud')} />
          </View>
        </Animated.View>
        )}
      </Animated.View>

      {voice.listening && !guideLens ? <ListeningOverlay transcript={voice.transcript} pen={pen} top={insets.top + 120} /> : null}

      <Flash ref={flash} />

      {drop ? <DropMenu top={insets.top + 64} onPick={(c) => void onDrop(c)} onClose={() => setDrop(false)} /> : null}

      {memories ? (
        <MemoriesSheet
          onOpen={(id, from) => {
            setOpen({ id, origin: from.w > 4 && from.h > 4 ? from : 'camera' });
          }}
          onClose={() => setMemories(false)}
        />
      ) : null}

      {open ? (
        <View style={[StyleSheet.absoluteFill, styles.top30]}>
          <CaptureView
            key={open.id}
            id={open.id}
            origin={open.origin}
            // Opened from a Memories print: go back into that print. From the camera: file it.
            dismissTo={open.origin === 'camera' ? memoriesRect : open.origin}
            onClosed={() => setOpen(null)}
          />
        </View>
      ) : null}

      {settingsOpen ? <SettingsSheet pen={pen} onClose={() => setSettingsOpen(false)} /> : null}
      <ToastHost />
    </View>
  );
}

/** Expo Router renders this instead of a white screen if anything throws. */
export function ErrorBoundary({ error, retry }: { error: Error; retry: () => Promise<void> }) {
  return (
    <View style={[styles.root, styles.crash]}>
      <Text style={styles.crashTitle}>That one slipped.</Text>
      <Text style={styles.crashBody}>Lensi hit a snag drawing that screen. Your captures are safe on the phone.</Text>
      <Text style={styles.crashCode} numberOfLines={3}>
        {error.message}
      </Text>
      <Text onPress={() => void retry()} style={styles.crashButton} accessibilityRole="button">
        Back to the camera
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  crash: { justifyContent: 'center', paddingHorizontal: 28, gap: 12, backgroundColor: '#0B0B0C' },
  crashTitle: { color: '#FFFFFF', ...face.semibold, fontSize: 32, letterSpacing: -0.3 },
  crashBody: { color: 'rgba(255,255,255,0.62)', ...face.regular, fontSize: 16, lineHeight: 22 },
  crashCode: { color: 'rgba(255,255,255,0.38)', ...face.medium, fontSize: 12.5, lineHeight: 16 },
  crashButton: {
    alignSelf: 'flex-start',
    marginTop: 12,
    overflow: 'hidden',
    paddingHorizontal: 18,
    paddingVertical: 13,
    borderRadius: 24,
    backgroundColor: '#E4FF4F',
    color: '#0B0B0C',
    ...face.bold,
    fontSize: 17,
  },
  top30: { zIndex: 30 },
  shade: { position: 'absolute', left: 0, right: 0 },
  top: { position: 'absolute', left: 14, right: 14, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start' },
  hintWrap: { position: 'absolute', alignSelf: 'center', paddingHorizontal: 14, height: 32, borderRadius: 16, justifyContent: 'center', backgroundColor: 'rgba(11,11,12,0.7)' },
  hint: { color: '#FFFFFF', ...face.semibold, fontSize: 14 },
  bottom: { position: 'absolute', left: 0, right: 0, bottom: 0, alignItems: 'center', gap: 6 },
  stack: { alignSelf: 'stretch', alignItems: 'center', gap: 6 },
  // Under the zoom dial while it's up.
  under: { opacity: 0 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', alignSelf: 'stretch', paddingHorizontal: 26 },
});

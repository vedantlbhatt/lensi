import { forwardRef, useImperativeHandle, useRef } from 'react';
import { Platform, StyleSheet } from 'react-native';

import {
  isVirtual,
  LensiARView,
  type DemoScene,
  type GuideChangeEvent,
  type GuideFrame,
  type LensiARViewRef,
  type SelectEvent,
  type TrackingEvent,
} from '../../../modules/lensi-ar/src';
import type { GuidePart } from '../../lib/guide';
import type { Picked } from '../../lib/media';
import { VirtualCamera, type VirtualHandle } from './VirtualCamera';

/** One camera API whether we have ARKit or the virtual stand-in. */
export type CameraHandle = {
  takePhoto(): Promise<Picked | null>;
  /** Resolves false when this camera can't record; rejects with a reason when it could but didn't. */
  startRecording(): Promise<boolean>;
  stopRecording(): Promise<Picked | null>;
  setTorch(on: boolean): Promise<boolean>;
  /** Virtual camera only: show the next/previous demo scene. */
  nextScene?(dir: 1 | -1): void;
  /** The native view, for live pins. Null on the virtual camera. */
  native?: LensiARViewRef | null;
  /**
   * Live guide. On ARKit the tags live in the world (native); on the virtual
   * camera they are drawn over the scene from `guidePins` instead, and these
   * calls only capture the frame.
   */
  guide: {
    capture(): Promise<GuideFrame | null>;
    pin(frameId: string, part: GuidePart): Promise<void>;
    focus(id: string | null): Promise<void>;
    watch(id: string | null): Promise<void>;
    clear(): Promise<void>;
  };
};

/** Tags the virtual camera draws for the live guide (the native one pins its own). */
export type VirtualGuidePins = { parts: GuidePart[]; focus: string | null };

export const CameraSurface = forwardRef<
  CameraHandle,
  {
    pen: string;
    brackets: boolean;
    livePins: boolean;
    paused: boolean;
    onFocusChange?: (label: string | null) => void;
    onTracking?: (e: TrackingEvent) => void;
    onSelect?: (e: SelectEvent) => void;
    onPinTap?: (id: string) => void;
    onScene?: (s: DemoScene) => void;
    onGuideChange?: (e: GuideChangeEvent) => void;
    guidePins?: VirtualGuidePins;
    /** Virtual camera only: which demo scene to show. */
    sceneKey?: string;
  }
>(function CameraSurface(props, ref) {
  const native = useRef<LensiARViewRef>(null);
  const virtual = useRef<VirtualHandle>(null);
  const onGuideChange = useRef(props.onGuideChange);
  onGuideChange.current = props.onGuideChange;
  // The web preview's camera is a still picture, so nothing it watches can
  // change. It fakes one change 7 s into watching a part, to show the flow.
  const fakeChange = useRef<ReturnType<typeof setTimeout> | null>(null);
  const faked = useRef(false);

  useImperativeHandle(
    ref,
    () => {
      if (isVirtual) {
        return {
          takePhoto: () => virtual.current?.takePhoto() ?? Promise.resolve(null),
          startRecording: () => virtual.current?.startRecording() ?? Promise.resolve(false),
          stopRecording: () => virtual.current?.stopRecording() ?? Promise.resolve(null),
          setTorch: () => Promise.resolve(false),
          nextScene: (dir: 1 | -1) => virtual.current?.nextScene?.(dir),
          native: null,
          guide: {
            capture: async () => {
              const p = await virtual.current?.takePhoto();
              return p ? { frameId: 'virtual', uri: p.uri, width: p.width, height: p.height } : null;
            },
            pin: async () => {},
            focus: async () => {},
            watch: async (id: string | null) => {
              if (fakeChange.current) clearTimeout(fakeChange.current);
              fakeChange.current = null;
              // The web preview fakes one change per job, to show the watch flow.
              if (Platform.OS !== 'web' || !id || faked.current) return;
              fakeChange.current = setTimeout(() => {
                faked.current = true;
                onGuideChange.current?.({ id, distance: 0.5 });
              }, 7000);
            },
            clear: async () => {
              if (fakeChange.current) clearTimeout(fakeChange.current);
              fakeChange.current = null;
              faked.current = false;
            },
          },
        };
      }
      return {
        takePhoto: async () => {
          const p = await native.current?.takePhoto();
          return p ? { kind: 'image', uri: p.uri, width: p.width, height: p.height, source: 'camera' } : null;
        },
        // Rejects with a readable reason (e.g. microphone permission pending).
        startRecording: async () => {
          await native.current?.startRecording();
          return true;
        },
        stopRecording: async () => {
          try {
            const v = await native.current?.stopRecording();
            return v ? { kind: 'video', uri: v.uri, width: v.width, height: v.height, durationMs: v.durationMs, source: 'video' } : null;
          } catch (e) {
            console.warn('[lensi] recording failed', e);
            return null;
          }
        },
        setTorch: async (on: boolean) => {
          try {
            return (await native.current?.setTorch(on)) ?? false;
          } catch {
            return false;
          }
        },
        get native() {
          return native.current;
        },
        guide: {
          capture: async () => (await native.current?.guideCapture()) ?? null,
          pin: async (frameId: string, part: GuidePart) => {
            await native.current?.guidePin(frameId, part.id, part.at.x, part.at.y, part.label);
          },
          focus: async (id: string | null) => {
            await native.current?.guideFocus(id);
          },
          watch: async (id: string | null) => {
            await native.current?.guideWatch(id);
          },
          clear: async () => {
            await native.current?.guideClear();
          },
        },
      };
    },
    [],
  );

  if (isVirtual) {
    return <VirtualCamera ref={virtual} pen={props.pen} brackets={props.brackets && !props.paused} onScene={props.onScene} guidePins={props.guidePins} sceneKey={props.sceneKey} />;
  }
  return (
    <LensiARView
      ref={native}
      style={StyleSheet.absoluteFill}
      showDetections={props.brackets && !props.paused}
      livePins={props.livePins}
      accentColor={props.pen}
      paused={props.paused}
      onFocusChange={(e) => props.onFocusChange?.(e.nativeEvent.label)}
      onTrackingChange={(e) => props.onTracking?.(e.nativeEvent)}
      onSelect={(e) => props.onSelect?.(e.nativeEvent)}
      onPinTap={(e) => props.onPinTap?.(e.nativeEvent.id)}
      onGuideChange={(e) => props.onGuideChange?.(e.nativeEvent)}
    />
  );
});

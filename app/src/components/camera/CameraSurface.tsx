import { forwardRef, useImperativeHandle, useRef } from 'react';
import { StyleSheet } from 'react-native';

import {
  isVirtual,
  LensiARView,
  type DemoScene,
  type LensiARViewRef,
  type SelectEvent,
  type TrackingEvent,
} from '../../../modules/lensi-ar/src';
import type { Picked } from '../../lib/media';
import { VirtualCamera } from './VirtualCamera';

/** One camera API whether we have ARKit or the virtual stand-in. */
export type CameraHandle = {
  takePhoto(): Promise<Picked | null>;
  /** Resolves false when this camera can't record. */
  startRecording(): Promise<boolean>;
  stopRecording(): Promise<Picked | null>;
  setTorch(on: boolean): Promise<boolean>;
  /** The native view, for live pins. Null on the virtual camera. */
  native?: LensiARViewRef | null;
};

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
  }
>(function CameraSurface(props, ref) {
  const native = useRef<LensiARViewRef>(null);
  const virtual = useRef<CameraHandle>(null);

  useImperativeHandle(
    ref,
    () => {
      if (isVirtual) {
        return {
          takePhoto: () => virtual.current?.takePhoto() ?? Promise.resolve(null),
          startRecording: () => virtual.current?.startRecording() ?? Promise.resolve(false),
          stopRecording: () => virtual.current?.stopRecording() ?? Promise.resolve(null),
          setTorch: () => Promise.resolve(false),
          native: null,
        };
      }
      return {
        takePhoto: async () => {
          const p = await native.current?.takePhoto();
          return p ? { kind: 'image', uri: p.uri, width: p.width, height: p.height, source: 'camera' } : null;
        },
        startRecording: async () => {
          try {
            await native.current?.startRecording();
            return true;
          } catch (e) {
            console.warn('[lensi] recording failed to start', e);
            return false;
          }
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
      };
    },
    [],
  );

  if (isVirtual) {
    return <VirtualCamera ref={virtual} pen={props.pen} brackets={props.brackets && !props.paused} onScene={props.onScene} />;
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
    />
  );
});

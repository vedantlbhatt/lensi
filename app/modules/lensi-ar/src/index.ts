import { requireNativeModule, requireNativeView } from 'expo';
import type { Ref } from 'react';
import type { ViewProps } from 'react-native';

export type SelectEvent = {
  id: string;
  /** On-device YOLO label, if the tap landed on a detected object. */
  label: string | null;
  confidence: number;
  /** Base64 JPEG of the subject crop (longest side ≤ 640). */
  image: string;
};

export type TrackingEvent = {
  state: 'normal' | 'limited' | 'unavailable';
  reason: '' | 'excessiveMotion' | 'insufficientFeatures' | 'initializing' | 'relocalizing' | 'unknown';
};

export type LensiARViewRef = {
  capture(): Promise<void>;
  setPin(id: string, title: string, color?: string | null): Promise<void>;
  /** x and y are 0…1 inside the crop sent with onSelect. */
  addCallout(parentId: string, id: string, x: number, y: number, text: string): Promise<void>;
  removePin(id: string): Promise<void>;
  clearPins(): Promise<void>;
};

export type LensiARViewProps = ViewProps & {
  ref?: Ref<LensiARViewRef>;
  showDetections?: boolean;
  onSelect?: (e: { nativeEvent: SelectEvent }) => void;
  onFocusChange?: (e: { nativeEvent: { label: string | null } }) => void;
  onTrackingChange?: (e: { nativeEvent: TrackingEvent }) => void;
  onPinTap?: (e: { nativeEvent: { id: string } }) => void;
};

const LensiAR = requireNativeModule<{ isSupported: boolean }>('LensiAR');

export const isSupported: boolean = LensiAR.isSupported;
export const LensiARView = requireNativeView<LensiARViewProps>('LensiAR');

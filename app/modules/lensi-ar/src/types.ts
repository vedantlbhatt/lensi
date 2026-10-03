import type { Ref } from 'react';
import type { ViewProps } from 'react-native';

export type NPt = { x: number; y: number };
/** Normalized rect, 0…1 in the upright image, top-left origin. */
export type NBox = { x: number; y: number; w: number; h: number };

export type SelectEvent = {
  id: string;
  /** On-device YOLO label, if the tap landed on a detected object. */
  label: string | null;
  confidence: number;
  /** Base64 JPEG of the subject crop (longest side ≤ 640). */
  image: string;
};

export type TrackingEvent = {
  /** `failed`: the camera never started (permission denied, sensor error). */
  state: 'normal' | 'limited' | 'unavailable' | 'failed';
  reason:
    | ''
    | 'excessiveMotion'
    | 'insufficientFeatures'
    | 'initializing'
    | 'relocalizing'
    | 'interrupted'
    | 'unknown'
    | 'cameraDenied'
    | 'failed';
};

export type PhotoResult = { uri: string; width: number; height: number };
export type VideoResult = { uri: string; width: number; height: number; durationMs: number };

export type LensiARViewRef = {
  /** Live mode: pin whatever is under the reticle. */
  capture(): Promise<void>;
  /** Full-resolution upright JPEG written to the caches directory. */
  takePhoto(): Promise<PhotoResult>;
  startRecording(): Promise<void>;
  stopRecording(): Promise<VideoResult>;
  setTorch(on: boolean): Promise<boolean>;
  setPin(id: string, title: string, color?: string | null): Promise<void>;
  /** x and y are 0…1 inside the crop sent with onSelect. */
  addCallout(parentId: string, id: string, x: number, y: number, text: string): Promise<void>;
  removePin(id: string): Promise<void>;
  clearPins(): Promise<void>;
};

export type LensiARViewProps = ViewProps & {
  ref?: Ref<LensiARViewRef>;
  /** Draw live detection brackets. */
  showDetections?: boolean;
  /** Taps pin objects in world space (live mode) instead of being ignored. */
  livePins?: boolean;
  /** Pen colour for the focused bracket and new pins, #RRGGBB. */
  accentColor?: string;
  /** Pause the AR session (e.g. while a capture is open on top). */
  paused?: boolean;
  onSelect?: (e: { nativeEvent: SelectEvent }) => void;
  onFocusChange?: (e: { nativeEvent: { label: string | null } }) => void;
  onTrackingChange?: (e: { nativeEvent: TrackingEvent }) => void;
  onPinTap?: (e: { nativeEvent: { id: string } }) => void;
};

export type Analysis = {
  width: number;
  height: number;
  /** The single most prominent foreground thing, if Vision found one. */
  subject: { box: NBox; polygon: NPt[] } | null;
  /** Every foreground instance, largest first (includes the subject). */
  instances: { box: NBox; polygon: NPt[] }[];
  text: { text: string; box: NBox; confidence: number }[];
  barcodes: { payload: string; symbology: string; box: NBox }[];
  objects: { label: string; confidence: number; box: NBox }[];
  /** Whole-image classification, best first. */
  labels: { label: string; confidence: number }[];
  salient: NBox[];
  ms: number;
};

export type Segment = { polygon: NPt[]; box: NBox; score: number; engine: 'sam' | 'vision' | 'demo' };

export type IntelligenceStatus = {
  /** The on-device Apple Foundation Model can run right now. */
  available: boolean;
  /** It accepts image attachments (iOS 27+). */
  images: boolean;
  /** Human-readable reason when unavailable. */
  reason: string;
};

/** Mirrors EngineEvent in src/lib/types.ts; marks refer to region.mark. */
export type IntelligenceEvent =
  | { requestId: string; type: 'event'; event: Record<string, unknown> }
  | { requestId: string; type: 'done' }
  | { requestId: string; type: 'error'; message: string };

export type SpeechEvent = { transcript: string; isFinal: boolean; level: number; error?: string };

export type LensiAREvents = {
  onIntelligence: (e: IntelligenceEvent) => void;
  onSpeech: (e: SpeechEvent) => void;
};

export type LensiARModuleShape = {
  isSupported: boolean;
  /** A lensi:// URL handed over in the launch environment (scripted runs), if any. */
  launchURL?: string | null;
  analyze(uri: string): Promise<Analysis>;
  /** Point prompt in normalized image coords. */
  segment(uri: string, x: number, y: number): Promise<Segment | null>;
  intelligenceStatus(): Promise<IntelligenceStatus>;
  /** `request` is JSON: { imageUri, lens, marks, question?, history?, walkthrough? }. */
  intelligenceStart(requestId: string, request: string): Promise<void>;
  intelligenceCancel(requestId: string): void;
  speechRequestPermission(): Promise<boolean>;
  speechStart(): Promise<void>;
  speechStop(): Promise<void>;
};

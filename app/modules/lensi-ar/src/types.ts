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
  /**
   * Live guide: grab the current frame (upright JPEG for the eyes and the
   * brain) and freeze its camera pose, so parts found in it can be pinned in
   * 3D later even if the phone has moved since.
   */
  guideCapture(): Promise<GuideFrame>;
  /** Pin a tag in the world at x, y (0…1 in that frame's upright image). */
  guidePin(frameId: string, id: string, x: number, y: number, label: string): Promise<void>;
  /** A pinned part's shape in its frame, as flat x,y pairs (upright, 0-1). */
  guideOutline(frameId: string, id: string, points: number[]): Promise<void>;
  /** The part the current step is about: its tag stands out, the others step back. Null for none. */
  guideFocus(id: string | null): Promise<void>;
  /** Watch the part for a change that settles (a cap off, a valve turned); fires onGuideChange. Null stops. */
  guideWatch(id: string | null): Promise<void>;
  guideClear(): Promise<void>;
  /** 0.5 (ultra-wide, where ARKit offers it) up to the camera's max; clamped natively. */
  setZoom(zoom: number): Promise<void>;
  /**
   * Follow one thing for the rest of the session: a tap (x, y), a box dragged around it
   * (x, y, w, h), all in view points; x < 0 = whatever is under the reticle. Fires onLockChange.
   */
  lockTarget(x: number, y: number, w: number, h: number): Promise<void>;
  unlockTarget(): Promise<void>;
};

/** The followed thing: whether there is one, and its name once the phone knows it. */
export type LockEvent = { locked: boolean; label: string | null };

export type GuideFrame = { frameId: string; uri: string; width: number; height: number };

export type GuideChangeEvent = {
  /** The watched part. */
  id: string;
  /** Feature-print distance from how the part looked when watching began. */
  distance: number;
};

export type LensiARViewProps = ViewProps & {
  ref?: Ref<LensiARViewRef>;
  /** Draw live detection brackets. */
  showDetections?: boolean;
  /** SAM on the live camera feed: guide parts, else the tracked thing, else the middle of the screen. */
  liveSegments?: boolean;
  /** Taps pin objects in world space (live mode) instead of being ignored. */
  livePins?: boolean;
  /** Pen colour for the focused bracket and new pins, #RRGGBB. */
  accentColor?: string;
  /** Pause the AR session (e.g. while a capture is open on top). */
  paused?: boolean;
  /** Room the app's chrome takes above and below (the guide panel): guide tags keep clear of it. */
  pinInsets?: { top: number; bottom: number };
  onSelect?: (e: { nativeEvent: SelectEvent }) => void;
  onFocusChange?: (e: { nativeEvent: { label: string | null } }) => void;
  onTrackingChange?: (e: { nativeEvent: TrackingEvent }) => void;
  onPinTap?: (e: { nativeEvent: { id: string } }) => void;
  onGuideChange?: (e: { nativeEvent: GuideChangeEvent }) => void;
  /** How far this camera zooms (min is 0.5 where the ultra-wide is available, else 1). */
  onZoomRange?: (e: { nativeEvent: ZoomRange }) => void;
  onLockChange?: (e: { nativeEvent: LockEvent }) => void;
};

export type ZoomRange = { min: number; max: number; zoom: number };

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
  /** SAM part proposals over the subject (buttons, knobs, handles), best first. */
  parts?: { polygon: NPt[]; box: NBox; score: number }[];
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
  /** `unavailable`: the model itself couldn't run (not a refusal or a bad request). */
  | { requestId: string; type: 'error'; message: string; unavailable?: boolean };

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
  /** Load the on-device model before the first question (no-op where there is none). */
  intelligencePrewarm(): Promise<void>;
  /** `request` is JSON: { imageUri, lens, marks, question?, history?, walkthrough? }. */
  intelligenceStart(requestId: string, request: string): Promise<void>;
  intelligenceCancel(requestId: string): Promise<void> | void;
  speechRequestPermission(): Promise<boolean>;
  speechStart(): Promise<void>;
  speechStop(): Promise<void>;
  /** Keep the screen from locking (a hands-free job has no touches for minutes). */
  setKeepAwake(on: boolean): Promise<void>;
};

import type { Lens } from '../theme/tokens';

export type { Lens };

/** Normalized point, 0…1 in the media's own upright pixel space, top-left origin. */
export type Pt = { x: number; y: number };
/** Normalized rect in the same space. */
export type Box = { x: number; y: number; w: number; h: number };

export type RegionKind = 'subject' | 'part' | 'text' | 'barcode' | 'object' | 'salient';

/**
 * Something the on-device eyes found. Regions are the only source of truth for
 * *where* things are; models only ever refer to them by `mark`, so a label can
 * never land in empty space.
 */
export type Region = {
  id: string;
  /** 1-based number drawn on the image for set-of-marks prompting. */
  mark: number;
  kind: RegionKind;
  box: Box;
  polygon?: Pt[];
  /** What the eyes think it is: OCR text, a barcode payload, a detector class. */
  text?: string;
  confidence?: number;
};

export type Callout = {
  id: string;
  label: string;
  detail?: string;
  at: Pt;
  regionId?: string;
  polygon?: Pt[];
};

export type Step = {
  id: string;
  text: string;
  at?: Pt;
  regionId?: string;
  polygon?: Pt[];
};

/** A part an answer refers to, so the pointer can show it while the answer is read. */
export type Pointing = {
  at: Pt;
  label: string;
  /** The label on the print for that part, when it has one. */
  calloutId?: string;
  polygon?: Pt[];
};

export type Exchange = {
  id: string;
  question: string;
  answer: string[];
  pending: boolean;
  /** Set when the answer turned into a walkthrough. */
  steps?: Step[];
  /** Parts the answer pointed at, in the order it named them. */
  points?: Pointing[];
};

export type EngineId = 'apple' | 'cloud' | 'vision';

export type Annotation = {
  title: string | null;
  summary: string | null;
  callouts: Callout[];
  facts: string[];
  steps: Step[];
  /** Follow-up questions the model thinks come next. Absent on old captures. */
  suggestions?: string[];
};

export type MediaKind = 'image' | 'video';
export type Source = 'camera' | 'video' | 'library' | 'files' | 'clipboard' | 'voice';

export type Media = {
  kind: MediaKind;
  /** Durable file URI inside the app's documents. */
  uri: string;
  width: number;
  height: number;
  durationMs?: number;
  /** Still frame used for analysis and thumbnails (the photo itself for images). */
  stillUri: string;
};

/** A video keyframe. `kept` holds its drawing once it has been annotated, so going back is instant. */
export type Moment = {
  /** Milliseconds into a video; for added photos, their order. */
  t: number;
  uri: string;
  /** Added photos carry their own size (a video's frames share the video's). */
  width?: number;
  height?: number;
  kept?: { subject: Region | null; regions: Region[]; annotation: Annotation; engine: EngineId | null };
};

export type Capture = {
  id: string;
  createdAt: number;
  source: Source;
  lens: Lens;
  media: Media;
  /** Video keyframes, analysed one at a time when the user scrubs to them. */
  moments: Moment[];
  subject: Region | null;
  regions: Region[];
  annotation: Annotation;
  thread: Exchange[];
  engine: EngineId | null;
  status: 'analyzing' | 'ready' | 'error';
  error: string | null;
  /** The spoken or typed question that started this capture, if any. */
  prompt: string | null;
  /** What the eyes reported before any naming (scene labels, detections, time): kept for debugging. */
  seen?: { labels: string[]; objects: string[]; ms: number };
};

export const emptyAnnotation = (): Annotation => ({
  title: null,
  summary: null,
  callouts: [],
  facts: [],
  steps: [],
  suggestions: [],
});

/** Everything an engine can say, in the order it is likely to say it. */
export type EngineEvent =
  | { kind: 'title'; text: string }
  | { kind: 'summary'; text: string }
  | { kind: 'callout'; label: string; mark?: number; at?: Pt; detail?: string }
  | { kind: 'fact'; text: string }
  | { kind: 'step'; text: string; mark?: number; at?: Pt }
  | { kind: 'answer'; text: string }
  | { kind: 'suggest'; text: string }
  | { kind: 'error'; text: string };

export type EngineRequest = {
  imageUri: string;
  width: number;
  height: number;
  lens: Lens;
  regions: Region[];
  /** On-device label for the main subject, a hint the model may overrule. */
  hint: string | null;
  question?: string;
  /** Earlier turns, oldest first, so follow-ups have context. */
  history?: { question: string; answer: string }[];
  /** Ask for a numbered walkthrough instead of an annotation. */
  walkthrough?: boolean;
};

export interface Engine {
  id: EngineId;
  name: string;
  /** Resolves quickly; never throws. */
  available(): Promise<boolean>;
  run(req: EngineRequest, emit: (e: EngineEvent) => void, signal: AbortSignal): Promise<void>;
}

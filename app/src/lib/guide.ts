import type { Pt } from './types';

/**
 * The live guide: someone mid-job (a car, a sink, a breaker box) with the
 * phone propped up and both hands busy. They say what they're doing; the app
 * pins short tags on the parts and walks them through it a step at a time,
 * checking each step when something changes where they're working.
 *
 * This file is the pure part: state, transitions and what a spoken phrase
 * means. useGuide (guideSession.ts) wires it to the camera, the brain and
 * the voice.
 */

/**
 * A tagged part, pinned where it was in the frame the plan was made from (or,
 * for one found later by a question, `frame`: the look that found it).
 * `outline` is its shape in that frame (SAM), drawn around it while its step is up.
 */
export type GuidePart = { id: string; label: string; at: Pt; mark?: number; outline?: Pt[]; frame?: string };

export type GuideStep = { text: string; partId?: string };

export type GuideNote = { text: string; tone: 'info' | 'done' | 'warn' };

export type GuideStatus = 'idle' | 'planning' | 'active' | 'checking' | 'answering' | 'finished';

export type GuideState = {
  status: GuideStatus;
  /** What they asked for, in their words. */
  task: string | null;
  title: string | null;
  steps: GuideStep[];
  parts: GuidePart[];
  index: number;
  /** A line for the panel: a check result, an answer, or why something failed. */
  note: GuideNote | null;
  /** Where to return once an answer is in. */
  resume?: GuideStatus;
};

export const initialGuide: GuideState = {
  status: 'idle',
  task: null,
  title: null,
  steps: [],
  parts: [],
  index: 0,
  note: null,
};

export type GuideAction =
  | { type: 'plan'; task: string }
  | { type: 'title'; text: string }
  | { type: 'step'; text: string; label?: string; at?: Pt; mark?: number; outline?: Pt[] }
  /**
   * A labelled part with no step of its own: what the eyes found when there is
   * no model, or what an answer pointed at (`frame`: the look it was found in;
   * `step`: the step it belongs to, if that step has no part yet).
   */
  | { type: 'part'; label: string; at: Pt; mark?: number; outline?: Pt[]; frame?: string; step?: number }
  /** A part's shape, once it's known. */
  | { type: 'outline'; id: string; outline: Pt[] }
  | { type: 'planned' }
  | { type: 'go'; index: number }
  | { type: 'next' }
  | { type: 'back' }
  | { type: 'checking' }
  | { type: 'checked'; done: boolean | null; text: string }
  | { type: 'answering' }
  | { type: 'note'; note: GuideNote | null }
  | { type: 'reset' };

/** Parts closer than this (in the frame's 0-1 space) are the same part. */
const SAME_PART = 0.05;
const MAX_PARTS = 6;

function addPart(
  parts: GuidePart[],
  label: string,
  at: Pt,
  mark?: number,
  outline?: Pt[],
  frame?: string,
): { parts: GuidePart[]; id: string | null } {
  const clean = shortLabel(label);
  if (!clean) return { parts, id: null };
  // Marks and points only compare within one look; across looks, the name does.
  const same = parts.find((p) =>
    (p.frame ?? null) === (frame ?? null)
      ? (mark !== undefined && p.mark === mark) || Math.hypot(p.at.x - at.x, p.at.y - at.y) < SAME_PART
      : p.label.toLowerCase() === clean.toLowerCase(),
  );
  if (same) return { parts, id: same.id };
  if (parts.length >= MAX_PARTS) return { parts, id: null };
  const id = `p${parts.length + 1}`;
  const shape = outline && outline.length >= 3 ? { outline: simplify(outline) } : {};
  const extra = { ...(mark !== undefined ? { mark } : {}), ...shape, ...(frame ? { frame } : {}) };
  return { parts: [...parts, { id, label: clean, at, ...extra }], id };
}

/** At most this many corners: an outline is redrawn every frame. */
const MAX_OUTLINE = 48;

/** Evenly thins a polygon to at most MAX_OUTLINE points. */
export function simplify(points: Pt[]): Pt[] {
  if (points.length <= MAX_OUTLINE) return points;
  const step = points.length / MAX_OUTLINE;
  return Array.from({ length: MAX_OUTLINE }, (_, i) => points[Math.floor(i * step)]);
}

/** Tags are short: at most three words, no trailing punctuation, first letter up. */
export function shortLabel(label: string): string {
  const words = label.trim().replace(/[.,;:!?]+$/, '').split(/\s+/).filter(Boolean).slice(0, 3);
  const s = words.join(' ');
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
}

export function guideReducer(s: GuideState, a: GuideAction): GuideState {
  switch (a.type) {
    case 'plan':
      return { ...initialGuide, status: 'planning', task: a.task.trim() };
    case 'title':
      return s.title ? s : { ...s, title: a.text };
    case 'step': {
      const placed = a.label && a.at ? addPart(s.parts, a.label, a.at, a.mark, a.outline) : { parts: s.parts, id: null };
      const step: GuideStep = { text: a.text.trim(), ...(placed.id ? { partId: placed.id } : {}) };
      if (!step.text) return s;
      // The first step is shown as soon as it arrives; the rest stream in behind it.
      return { ...s, parts: placed.parts, steps: [...s.steps, step], status: s.status === 'planning' ? 'active' : s.status };
    }
    case 'part': {
      const placed = addPart(s.parts, a.label, a.at, a.mark, a.outline, a.frame);
      const owner = a.step !== undefined ? s.steps[a.step] : undefined;
      // Found for a step that had nothing to point at: now it does.
      const steps = owner && placed.id && !owner.partId ? s.steps.map((st, i) => (i === a.step ? { ...st, partId: placed.id! } : st)) : s.steps;
      return { ...s, parts: placed.parts, steps };
    }
    case 'outline':
      if (a.outline.length < 3) return s;
      return { ...s, parts: s.parts.map((p) => (p.id === a.id && !p.outline ? { ...p, outline: simplify(a.outline) } : p)) };
    case 'planned':
      // Steps may have been under way for a while; only a plan still waiting changes state.
      if (s.status !== 'planning') return s;
      return { ...s, status: s.steps.length || s.parts.length ? 'active' : 'idle' };
    case 'go': {
      if (!s.steps.length) return s;
      const index = Math.max(0, Math.min(s.steps.length - 1, a.index));
      return { ...s, index, status: 'active', note: null };
    }
    case 'next':
      if (!s.steps.length) return s;
      if (s.index >= s.steps.length - 1) return { ...s, status: 'finished', note: { text: 'That was the last step.', tone: 'done' } };
      return { ...s, index: s.index + 1, status: 'active', note: null };
    case 'back':
      if (!s.steps.length) return s;
      return { ...s, index: Math.max(0, s.index - 1), status: 'active', note: null };
    case 'checking':
      return s.status === 'active' ? { ...s, status: 'checking' } : s;
    case 'checked':
      return {
        ...s,
        status: s.status === 'checking' ? 'active' : s.status,
        note: { text: a.text, tone: a.done === true ? 'done' : a.done === false ? 'warn' : 'info' },
      };
    case 'answering':
      // A question cuts a running check short; the guide comes back to the step.
      if (s.status === 'checking') return { ...s, status: 'answering', resume: 'active' };
      return s.status === 'active' || s.status === 'finished' ? { ...s, status: 'answering', resume: s.status } : s;
    case 'note':
      return s.status === 'answering' ? { ...s, note: a.note, status: s.resume ?? 'active', resume: undefined } : { ...s, note: a.note };
    case 'reset':
      return initialGuide;
  }
}

/** The current step, and the part it touches (if it has one). */
export function currentStep(s: GuideState): { step: GuideStep | null; part: GuidePart | null } {
  const step = s.steps[s.index] ?? null;
  const part = step?.partId ? (s.parts.find((p) => p.id === step.partId) ?? null) : null;
  return { step, part };
}

export type GuideCommand =
  | { type: 'next' | 'back' | 'repeat' | 'check' | 'stop' }
  /** Stop listening hands free, but carry on with the job. */
  | { type: 'mute' }
  | { type: 'ask'; text: string };

const COMMANDS: [GuideCommand['type'], RegExp][] = [
  [
    'next',
    /^((ok(ay)?|alright|right|yes|yep|cool|great) )?(next|next one|next step|go on|continue|keep going|done|i'?m done|that'?s done|all done|finished|got it|did it|what'?s next|what is next|what'?s the next step)$/,
  ],
  ['back', /^(go )?(back|previous|previous step|last step|step back|back a step)$/],
  ['repeat', /^(repeat|repeat (that|it|the step)|again|say (that|it) again|say again|what was that|come again|one more time|pardon|sorry what)$/],
  [
    'check',
    /^(check|check (it|this|that)|is (it|this|that) (right|ok(ay)?|done|good)|did i do (it|that) right|does (it|this|that) look (right|ok(ay)?|good)|how does (it|this|that) look|how'?s (it|this|that)|look|look at (it|this|that))$/,
  ],
  ['mute', /^(stop listening|be quiet|quiet|mute|shut up|go to sleep|pause listening)$/],
  ['stop', /^(stop|cancel|start over|new job|never ?mind|quit|reset)$/],
];

/**
 * What a spoken (or typed) phrase means. Only short phrases count as commands,
 * so "what's next to the valve" is a question, not "next". Punctuation the
 * recogniser adds, and a "please" or an "um" around a command, don't matter.
 */
export function parseCommand(raw: string): GuideCommand | null {
  const text = raw.trim();
  if (!text) return null;
  const plain = text
    .toLowerCase()
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[.!?,;:]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^((please|so|um|uh|and|now|hey) )+/, '')
    .replace(/( (please|thanks|thank you))+$/, '');
  if (plain && plain.split(' ').length <= 5) {
    for (const [type, re] of COMMANDS) {
      if (re.test(plain)) return { type } as GuideCommand;
    }
  }
  return { type: 'ask', text };
}

/** "Lensi, …" or "hey Lensi …" just says who it's for (as the recogniser tends to spell it). */
const ADDRESS = /^((hey|hi|ok(ay)?|so)[\s,]+)?(lensi|lenzi|lensy|lenzy|lenzie)\b[\s,.:!?]*/i;

/** Opens that put something to the app, as opposed to talk in the room. */
const REQUEST =
  /^(how|what|what'?s|where|where'?s|which|why|when|who|is|are|was|were|can|could|should|would|will|do|does|did|have|has|tell me|show me|help|explain|find|i can'?t|i cannot|i don'?t|it won'?t|it doesn'?t|it isn'?t|it'?s (stuck|not)|there'?s no|wait)\b/;

/**
 * What heard speech means. Tapped to talk, everything is for the app. Hands
 * free, the mic hears the whole room too, so besides the short commands only
 * a question, or something said to Lensi by name, counts; the rest is let go.
 */
export function heard(raw: string, handsFree: boolean): GuideCommand | null {
  const trimmed = raw.trim();
  const addressed = ADDRESS.test(trimmed);
  const text = trimmed.replace(ADDRESS, '').trim();
  const cmd = parseCommand(text);
  if (!cmd || cmd.type !== 'ask' || !handsFree || addressed) return cmd;
  const plain = text.toLowerCase();
  return plain.includes('?') || (REQUEST.test(plain) && plain.split(/\s+/).length >= 2) ? cmd : null;
}

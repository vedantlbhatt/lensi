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

/** A tagged part, pinned where it was in the frame the plan was made from. */
export type GuidePart = { id: string; label: string; at: Pt; mark?: number };

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
  | { type: 'step'; text: string; label?: string; at?: Pt; mark?: number }
  /** A labelled part with no step of its own (what the eyes found when there is no model). */
  | { type: 'part'; label: string; at: Pt; mark?: number }
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

function addPart(parts: GuidePart[], label: string, at: Pt, mark?: number): { parts: GuidePart[]; id: string | null } {
  const clean = shortLabel(label);
  if (!clean) return { parts, id: null };
  const same = parts.find((p) => (mark !== undefined && p.mark === mark) || Math.hypot(p.at.x - at.x, p.at.y - at.y) < SAME_PART);
  if (same) return { parts, id: same.id };
  if (parts.length >= MAX_PARTS) return { parts, id: null };
  const id = `p${parts.length + 1}`;
  return { parts: [...parts, { id, label: clean, at, ...(mark !== undefined ? { mark } : {}) }], id };
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
      const placed = a.label && a.at ? addPart(s.parts, a.label, a.at, a.mark) : { parts: s.parts, id: null };
      const step: GuideStep = { text: a.text.trim(), ...(placed.id ? { partId: placed.id } : {}) };
      if (!step.text) return s;
      return { ...s, parts: placed.parts, steps: [...s.steps, step] };
    }
    case 'part':
      return { ...s, parts: addPart(s.parts, a.label, a.at, a.mark).parts };
    case 'planned':
      return { ...s, status: s.steps.length || s.parts.length ? 'active' : 'idle', index: 0 };
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
  | { type: 'ask'; text: string };

const COMMANDS: [GuideCommand['type'], RegExp][] = [
  ['next', /^(ok(ay)?|alright|right|yes|yep)?[\s,]*(next|next one|next step|go on|continue|done|i'?m done|that'?s done|finished|got it|did it)$/],
  ['back', /^(go )?(back|previous|previous step|last step|step back)$/],
  ['repeat', /^(repeat|again|say (that|it) again|what was that|come again|one more time)$/],
  ['check', /^(check|check (it|this|that)|is (it|this|that) (right|ok(ay)?|done)|did i do (it|that) right|look)$/],
  ['stop', /^(stop|cancel|start over|new job|never ?mind|quit|reset)$/],
];

/**
 * What a spoken (or typed) phrase means. Only short phrases count as commands,
 * so "what's next to the valve" is a question, not "next".
 */
export function parseCommand(raw: string): GuideCommand | null {
  const text = raw.trim();
  if (!text) return null;
  const words = text.split(/\s+/).length;
  const plain = text.toLowerCase().replace(/[.!?]+$/g, '').replace(/\s+/g, ' ').trim();
  if (words <= 5) {
    for (const [type, re] of COMMANDS) {
      if (re.test(plain)) return { type } as GuideCommand;
    }
  }
  return { type: 'ask', text };
}

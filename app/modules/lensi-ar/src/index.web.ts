// Web build: no camera, no Vision, no Apple Intelligence. Everything here is a
// stand-in driven by the demo scenes so the UI and its motion can be developed
// and screenshotted in a browser.
import type { ComponentType } from 'react';

import { DEMO_SCENES, onSceneTracks, sceneForUri, sceneTracks, setSceneTracks, type DemoScene } from './demo';
import type {
  Analysis,
  DemoVideoProps,
  IntelligenceEvent,
  IntelligenceStatus,
  LensiAREvents,
  LensiARViewProps,
  NBox,
  NPt,
  Segment,
  SpeechEvent,
  TrackRun,
} from './types';

export * from './types';
export type { DemoScene, VideoThing, VideoTracks } from './demo';
/** No native player on the web: the virtual camera draws its footage with expo-video and SVG. */
export const DemoVideoView: ComponentType<DemoVideoProps> | null = null;
export { DEMO_SCENES, onSceneTracks, sceneForUri, sceneTracks, setSceneTracks };

type Listener<K extends keyof LensiAREvents> = LensiAREvents[K];
const listeners: { [K in keyof LensiAREvents]: Set<Listener<K>> } = {
  onIntelligence: new Set(),
  onSpeech: new Set(),
};
const timers = new Map<string, ReturnType<typeof setTimeout>[]>();
let demoQuestion = 'How do I use this?';
let speechTimer: ReturnType<typeof setInterval> | null = null;
let heard = '';
/** Hands-free films: what is said when the mic opens by itself. */
let talk: string[] = [];
// A mic opened by a hand (a tap or a hold) hears the scene's question; one
// that hands free opened by itself hears the script, or nothing.
let lastTouch = 0;
if (typeof window !== 'undefined') {
  for (const ev of ['pointerdown', 'pointerup', 'keyup']) window.addEventListener(ev, () => (lastTouch = Date.now()), true);
}

/** The fake recogniser "hears" the current scene's question, a word at a time. */
export function setDemoQuestion(q: string) {
  demoQuestion = q;
}

/**
 * Script what is said hands free (a film): each time the mic opens by itself
 * it waits a moment, then says the next line; once they run out it hears
 * nothing. A line is only used up once its first word is heard, so a mic that
 * closes early (the app started talking) hears it next time.
 * `"4:check"` waits 4 s of quiet before saying it (2.4 s otherwise).
 */
export function setDemoTalk(lines: string[]) {
  talk = lines.map((l) => l.trim()).filter(Boolean);
}

const box = (b: [number, number, number, number]): NBox => ({ x: b[0], y: b[1], w: b[2], h: b[3] });
const poly = (s: DemoScene): NPt[] => s.outline.polygon.map(([x, y]) => ({ x, y }));

function inside(p: NPt, pts: NPt[]): boolean {
  let hit = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const a = pts[i];
    const b = pts[j];
    if (a.y > p.y !== b.y > p.y && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y + 1e-12) + a.x) hit = !hit;
  }
  return hit;
}

function emit(e: IntelligenceEvent) {
  listeners.onIntelligence.forEach((fn) => fn(e));
}

export const LensiAR = {
  isSupported: false,
  launchURL: null as string | null,
  runtime: null as string | null,

  addListener<K extends keyof LensiAREvents>(name: K, fn: LensiAREvents[K]) {
    (listeners[name] as Set<LensiAREvents[K]>).add(fn);
    return { remove: () => (listeners[name] as Set<LensiAREvents[K]>).delete(fn) };
  },

  async analyze(uri: string): Promise<Analysis> {
    const s = sceneForUri(uri);
    await new Promise((r) => setTimeout(r, 380));
    if (!s) {
      const b = { x: 0.2, y: 0.25, w: 0.6, h: 0.5 };
      return { width: 1000, height: 1000, subject: null, instances: [], text: [], barcodes: [], objects: [], labels: [], salient: [b], ms: 3 };
    }
    const subject = { box: box(s.outline.box), polygon: poly(s) };
    return {
      width: s.width,
      height: s.height,
      subject,
      instances: [subject],
      text: s.text.map((t) => ({ text: t.text, box: box(t.box), confidence: 0.92 })),
      barcodes: [],
      objects: s.objects.map((o) => ({ label: o.label, confidence: 0.81, box: box(o.box) })),
      labels: s.labels.map((label, i) => ({ label, confidence: 0.9 - i * 0.2 })),
      salient: [subject.box],
      // The precomputed MobileSAM outlines stand in for the native part proposals.
      parts: s.parts.map((p) => {
        const polygon = p.polygon.map(([x, y]) => ({ x, y }));
        const xs = polygon.map((q) => q.x);
        const ys = polygon.map((q) => q.y);
        const x = Math.min(...xs);
        const y = Math.min(...ys);
        return { polygon, box: { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y }, score: 0.9 };
      }),
      ms: 14,
    };
  },

  async segment(uri: string, x: number, y: number): Promise<Segment | null> {
    const s = sceneForUri(uri);
    if (!s) return null;
    await new Promise((r) => setTimeout(r, 160));
    // Precomputed MobileSAM outline nearest the point, if one is close enough.
    const near = s.parts
      .map((p) => ({ p, d: Math.hypot(p.at[0] - x, p.at[1] - y) }))
      .sort((a, b) => a.d - b.d)[0];
    if (!near || near.d > 0.1) return null;
    const polygon = near.p.polygon.map(([px, py]) => ({ x: px, y: py }));
    const xs = polygon.map((q) => q.x);
    const ys = polygon.map((q) => q.y);
    const b = { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
    return { polygon, box: b, score: 0.9, engine: 'demo' };
  },

  async intelligencePrewarm() {},

  // No Core ML on the web.
  async trackVideo(): Promise<TrackRun> {
    throw new Error('EdgeTAM runs on iOS only');
  },

  async intelligenceStatus(): Promise<IntelligenceStatus> {
    return { available: true, images: true, reason: 'Scripted demo (web preview)' };
  },

  async intelligenceStart(requestId: string, request: string): Promise<void> {
    const req = JSON.parse(request) as {
      imageUri: string;
      question?: string;
      walkthrough?: boolean;
      guide?: boolean;
      check?: string | null;
      marks?: { mark: number; kind: string; box: { x: number; y: number; w: number; h: number } }[];
    };
    const s = sceneForUri(req.imageUri);
    const list: ReturnType<typeof setTimeout>[] = [];
    timers.set(requestId, list);
    let t = 520;
    const at = (delay: number, event: Record<string, unknown>) => {
      t += delay;
      list.push(setTimeout(() => emit({ requestId, type: 'event', event }), t));
    };
    if (req.check) {
      // Scripted: the preview has no live camera to look at, so every check passes.
      at(900, { kind: 'check', done: true, text: 'Looks done from here.' });
    } else if (!s) {
      at(0, { kind: 'title', text: 'Something new' });
      at(500, { kind: 'summary', text: 'The web preview only knows its demo scenes.' });
    } else if (req.walkthrough) {
      const sc = s.script;
      at(0, { kind: 'title', text: sc.title });
      // Each step's part, named by the scripted label nearest to where it points.
      const partNear = (p?: [number, number]) =>
        p
          ? [...sc.callouts]
              .map((c) => ({ c, d: Math.hypot(c.at[0] - p[0], c.at[1] - p[1]) }))
              .filter((x) => x.d < 0.22)
              .sort((a, b) => a.d - b.d)[0]?.c.label
          : undefined;
      sc.steps.forEach((st, i) =>
        at(i === 0 ? 300 : 420, {
          kind: 'step',
          text: st.text,
          at: st.at && { x: st.at[0], y: st.at[1] },
          ...(req.guide && partNear(st.at) ? { label: partNear(st.at) } : {}),
        }),
      );
    } else if (req.question) {
      // "What's this?" about a tapped mark: name the scripted part nearest to it.
      const sc = s.script;
      const tapped = /mark (\d+)/.exec(req.question)?.[1];
      const m = req.marks?.find((x) => String(x.mark) === tapped);
      if (m) {
        const cx = m.box.x + m.box.w / 2;
        const cy = m.box.y + m.box.h / 2;
        const near = [...sc.callouts].sort(
          (a, b) => Math.hypot(a.at[0] - cx, a.at[1] - cy) - Math.hypot(b.at[0] - cx, b.at[1] - cy),
        )[0];
        at(0, { kind: 'answer', text: `That's the ${near.label.toLowerCase()}.` });
        at(380, { kind: 'answer', text: sc.facts[0] });
        at(300, { kind: 'callout', label: near.label, mark: m.mark });
      } else {
        // Point at the part the question names, or at the two that matter most.
        // (A guide question carries the step it was asked on; that isn't what it names.)
        const q = req.question.split(' (They are on this step:')[0].toLowerCase();
        const named = sc.callouts.find((c) => c.label.toLowerCase().split(/[\s-]+/).some((w) => w.length > 3 && q.includes(w)));
        at(0, { kind: 'answer', text: named ? `That's the ${named.label.toLowerCase()}.` : sc.summary });
        at(380, { kind: 'answer', text: sc.facts[0] });
        for (const c of named ? [named] : sc.callouts.slice(0, 2)) {
          at(300, { kind: 'callout', label: c.label, at: { x: c.at[0], y: c.at[1] } });
        }
      }
    } else {
      const sc = s.script;
      at(0, { kind: 'title', text: sc.title });
      at(520, { kind: 'summary', text: sc.summary });
      sc.callouts.forEach((c) => at(300, { kind: 'callout', label: c.label, at: { x: c.at[0], y: c.at[1] } }));
      sc.facts.forEach((f) => at(260, { kind: 'fact', text: f }));
      sc.suggestions.forEach((q) => at(120, { kind: 'suggest', text: q }));
    }
    list.push(setTimeout(() => {
      emit({ requestId, type: 'done' });
      timers.delete(requestId);
    }, t + 200));
  },

  intelligenceCancel(requestId: string) {
    timers.get(requestId)?.forEach(clearTimeout);
    timers.delete(requestId);
  },

  async speechRequestPermission() {
    return true;
  },
  async speechStart() {
    if (speechTimer) clearInterval(speechTimer);
    heard = '';
    const scripted = Date.now() - lastTouch > 400;
    const raw = scripted ? (talk[0] ?? '') : demoQuestion;
    const timed = /^(\d+(?:\.\d+)?):(.*)$/.exec(raw);
    const line = (timed ? timed[2] : raw).trim();
    const words = line ? line.split(' ') : [];
    // A scripted turn starts after a beat of quiet, like someone finishing a turn of the wrench.
    const quietUntil = Date.now() + (scripted ? (timed ? Number(timed[1]) * 1000 : 2400) : 0);
    let i = 0;
    speechTimer = setInterval(() => {
      const talking = Date.now() >= quietUntil && i < words.length;
      if (talking) {
        if (i === 0 && scripted) talk.shift();
        heard = words.slice(0, ++i).join(' ');
      }
      const e: SpeechEvent = { transcript: heard, isFinal: false, level: talking ? 0.35 + Math.random() * 0.5 : 0.03 + Math.random() * 0.05 };
      listeners.onSpeech.forEach((fn) => fn(e));
    }, 230);
  },
  async setKeepAwake(_on: boolean) {},
  async speechStop() {
    if (speechTimer) clearInterval(speechTimer);
    speechTimer = null;
    const e: SpeechEvent = { transcript: heard, isFinal: true, level: 0 };
    listeners.onSpeech.forEach((fn) => fn(e));
  },
};

export const isSupported = false;
export const isVirtual = true;
export const LensiARView: ComponentType<LensiARViewProps> = () => null;

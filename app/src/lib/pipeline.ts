import { LensiAR } from '../../modules/lensi-ar/src';
import { pickEngine } from './engines';
import { boundsOf, dist, polygonArea } from './geometry';
import { normalizeStill, videoMoments, type Picked } from './media';
import { captureDir, keep } from './persist';
import { anchorFor, buildRegions, regionAt, regionArea, type AnalysisLike } from './regions';
import { getSettings } from './settings';
import { addCapture, getCapture, patchCapture } from './store';
import {
  emptyAnnotation,
  type Capture,
  type EngineEvent,
  type Exchange,
  type Lens,
  type Pt,
  type Region,
  type Step,
} from './types';

const uid = () => `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 7)}`;

const HOW_TO =
  /\b(how (do|can|to|would|should|does)|walk me|step[s ]|steps$|guide me|show me how|set ?up|install|assemble|replace|reset|clean|descale|fix|repair|turn (it )?(on|off)|open|close|connect|change|adjust|use (this|it))\b/i;

/** Questions that want a walkthrough rather than an answer. */
export function isHowTo(q: string): boolean {
  return HOW_TO.test(q);
}

const controllers = new Map<string, AbortController>();
const MAX_CALLOUTS = 6;

/**
 * Turns whatever the user gave us into a saved capture and starts analysing it.
 * Returns the capture id immediately so the UI can show the media while the
 * eyes and the model work.
 */
export async function ingest(
  picked: Picked,
  opts: { lens: Lens; prompt?: string | null; walkthrough?: boolean },
): Promise<string> {
  const id = uid();
  const dir = captureDir(id);
  const ext = picked.kind === 'video' ? (picked.uri.match(/\.(\w{2,4})(\?|$)/)?.[1] ?? 'mov') : 'jpg';
  const uri = await keep(picked.uri, dir, `media.${ext}`);

  let still = { uri, width: picked.width, height: picked.height };
  let moments: Capture['moments'] = [];
  if (picked.kind === 'video') {
    moments = await videoMoments(uri, picked.durationMs);
    const mid = moments[Math.floor(moments.length / 2)] ?? moments[0];
    if (mid) still = { uri: mid.uri, width: picked.width, height: picked.height };
    moments = await Promise.all(moments.map(async (m, i) => ({ t: m.t, uri: await keep(m.uri, dir, `moment-${i}.jpg`) })));
    const keptMid = moments[Math.floor(moments.length / 2)] ?? moments[0];
    if (keptMid) still = { ...still, uri: keptMid.uri };
  } else {
    still = await normalizeStill(uri, picked.width, picked.height);
  }

  const capture: Capture = {
    id,
    createdAt: Date.now(),
    source: picked.source,
    lens: opts.lens,
    media: {
      kind: picked.kind,
      uri,
      width: picked.width,
      height: picked.height,
      durationMs: picked.durationMs,
      stillUri: still.uri,
    },
    moments,
    subject: null,
    regions: [],
    annotation: emptyAnnotation(),
    thread: [],
    engine: null,
    status: 'analyzing',
    error: null,
    prompt: opts.prompt ?? null,
  };
  addCapture(capture);
  void analyze(id, { walkthrough: opts.walkthrough ?? (opts.lens === 'guide' || (!!opts.prompt && isHowTo(opts.prompt))) });
  return id;
}

async function runEyes(c: Capture): Promise<{ subject: Region | null; regions: Region[]; hint: string | null }> {
  try {
    const a = (await LensiAR.analyze(c.media.stillUri)) as AnalysisLike & { labels: { label: string }[] };
    const { subject, regions } = buildRegions(a);
    return { subject, regions, hint: subject?.text ?? a.labels[0]?.label ?? null };
  } catch (e) {
    console.warn('[lensi] analysis failed', e);
    return { subject: null, regions: [], hint: null };
  }
}

/** Eyes first (instant, on-device), then whichever brain is available. */
export async function analyze(id: string, opts: { walkthrough: boolean }) {
  const c0 = getCapture(id);
  if (!c0) return;
  controllers.get(id)?.abort();
  const controller = new AbortController();
  controllers.set(id, controller);

  const eyes = await runEyes(c0);
  if (controller.signal.aborted) return;
  patchCapture(id, (c) => ({ ...c, subject: eyes.subject, regions: eyes.regions }));

  const engine = await pickEngine(getSettings().brain);
  if (controller.signal.aborted) return;
  patchCapture(id, (c) => ({ ...c, engine: engine.id }));

  const c = getCapture(id)!;
  const question = c.prompt ?? undefined;
  // A spoken question that isn't a how-to gets an answer thread of its own.
  const exchangeId = question && !opts.walkthrough ? startExchange(id, question, false) : null;

  try {
    await engine.run(
      {
        imageUri: c.media.stillUri,
        width: c.media.width,
        height: c.media.height,
        lens: c.lens,
        regions: eyes.regions,
        hint: eyes.hint,
        question,
        walkthrough: opts.walkthrough,
      },
      (e) => apply(id, e, exchangeId),
      controller.signal,
    );
    if (controller.signal.aborted) return;
    patchCapture(id, (cur) => ({
      ...cur,
      status: cur.status === 'error' ? 'error' : 'ready',
      thread: cur.thread.map((x) => (x.id === exchangeId ? { ...x, pending: false } : x)),
    }));
  } catch (e) {
    if (controller.signal.aborted) return;
    const msg = engine.id === 'cloud' ? "Can't reach the Lensi server." : 'Something went wrong while thinking.';
    patchCapture(id, (cur) => ({ ...cur, status: 'error', error: msg }));
    console.warn('[lensi] engine failed', e);
  } finally {
    if (controllers.get(id) === controller) controllers.delete(id);
  }
}

function startExchange(id: string, question: string, walkthrough: boolean): string {
  const ex: Exchange = { id: uid(), question, answer: [], pending: true, steps: walkthrough ? [] : undefined };
  patchCapture(id, (c) => ({ ...c, thread: [...c.thread, ex] }));
  return ex.id;
}

/**
 * A follow-up question about a capture. How-to questions become walkthroughs.
 * `display` is what the thread shows when the model needs a fuller prompt.
 */
export async function ask(id: string, question: string, opts: { walkthrough?: boolean; display?: string } = {}) {
  const c = getCapture(id);
  if (!c) return;
  const walkthrough = opts.walkthrough ?? isHowTo(question);
  const exchangeId = startExchange(id, opts.display ?? question, walkthrough);
  const controller = new AbortController();
  controllers.get(`${id}:ask`)?.abort();
  controllers.set(`${id}:ask`, controller);

  const engine = await pickEngine(getSettings().brain);
  const current = getCapture(id) ?? c;
  const history = c.thread
    .filter((x) => !x.pending)
    .map((x) => ({ question: x.question, answer: [...x.answer, ...(x.steps ?? []).map((s, i) => `${i + 1}. ${s.text}`)].join(' ') }));
  try {
    await engine.run(
      {
        imageUri: c.media.stillUri,
        width: c.media.width,
        height: c.media.height,
        lens: c.lens,
        regions: current.regions,
        hint: c.annotation.title ?? c.subject?.text ?? null,
        question,
        history,
        walkthrough,
      },
      (e) => apply(id, e, exchangeId),
      controller.signal,
    );
  } catch (e) {
    if (!controller.signal.aborted) {
      patchExchange(id, exchangeId, (x) => ({ ...x, answer: [...x.answer, "Couldn't get an answer just now."] }));
    }
  } finally {
    patchExchange(id, exchangeId, (x) => ({ ...x, pending: false }));
    if (controllers.get(`${id}:ask`) === controller) controllers.delete(`${id}:ask`);
  }
}

/**
 * "What's this?" for a tapped point: the segmenter outlines the part under
 * the finger, it joins the capture as a new numbered mark, and the model is
 * asked about that mark. Returns the outline for immediate feedback.
 */
export async function askAbout(id: string, at: Pt): Promise<Pt[] | null> {
  const c = getCapture(id);
  if (!c) return null;
  let polygon: Pt[] | undefined;
  try {
    const seg = await LensiAR.segment(c.media.stillUri, at.x, at.y);
    if (seg && seg.polygon.length > 2) polygon = seg.polygon;
  } catch {}
  const mark = Math.max(0, ...c.regions.map((r) => r.mark)) + 1;
  const box = polygon ? boundsOf(polygon) : { x: Math.max(0, at.x - 0.04), y: Math.max(0, at.y - 0.04), w: 0.08, h: 0.08 };
  const region: Region = { id: `r${mark}`, mark, kind: 'part', box, polygon };
  patchCapture(id, (x) => ({ ...x, regions: [...x.regions, region] }));
  void ask(id, `The user tapped the part at mark ${mark}. What is it, and what is it for? Label it.`, {
    walkthrough: false,
    display: "What's this?",
  });
  return polygon ?? null;
}

/** Video: annotate a different keyframe. Clears the old drawing; keeps the thread. */
export function switchMoment(id: string, uri: string) {
  const c = getCapture(id);
  if (!c || c.media.stillUri === uri) return;
  cancel(id);
  patchCapture(id, (x) => ({
    ...x,
    media: { ...x.media, stillUri: uri },
    subject: null,
    regions: [],
    annotation: emptyAnnotation(),
    status: 'analyzing',
    error: null,
  }));
  void analyze(id, { walkthrough: false });
}

export function cancel(id: string) {
  controllers.get(id)?.abort();
  controllers.get(`${id}:ask`)?.abort();
}

function patchExchange(id: string, exchangeId: string, fn: (x: Exchange) => Exchange) {
  patchCapture(id, (c) => ({ ...c, thread: c.thread.map((x) => (x.id === exchangeId ? fn(x) : x)) }));
}

type Placement = { at: Pt; regionId?: string; polygon?: Region['polygon'] };

/** Resolve where an engine's callout or step belongs, preferring real regions. */
function place(c: Capture, mark?: number, at?: Pt): Placement | null {
  const subject = c.subject;
  const isPart = (r: Region) => r.kind !== 'subject' && !!r.polygon && r.polygon.length > 2;
  if (mark) {
    const r = c.regions.find((x) => x.mark === mark);
    if (r) return { at: anchorFor(r), regionId: r.id, polygon: isPart(r) ? r.polygon : undefined };
  }
  if (at) {
    const r = regionAt(at, c.regions);
    // Keep the engine's own point (it is usually more precise than a box center)
    // and borrow the region's outline only when the region is a small part.
    const small = r && subject ? regionArea(r) < regionArea(subject) * 0.5 : false;
    return { at, regionId: r?.id, polygon: r && isPart(r) && small ? r.polygon : undefined };
  }
  if (subject) return { at: anchorFor(subject), regionId: subject.id };
  return null;
}

function apply(id: string, e: EngineEvent, exchangeId: string | null) {
  const c = getCapture(id);
  if (!c) return;
  switch (e.kind) {
    case 'title':
      if (exchangeId && c.annotation.title) return;
      return patchCapture(id, (x) => ({ ...x, annotation: { ...x.annotation, title: e.text } }));
    case 'summary':
      if (exchangeId && c.annotation.summary) return;
      return patchCapture(id, (x) => ({ ...x, annotation: { ...x.annotation, summary: e.text } }));
    case 'fact':
      return patchCapture(id, (x) => ({ ...x, annotation: { ...x.annotation, facts: [...x.annotation.facts, e.text] } }));
    case 'suggest': {
      const q = e.text.trim();
      if (!q) return;
      return patchCapture(id, (x) => {
        const cur = x.annotation.suggestions ?? [];
        if (cur.length >= 3 || cur.some((s) => s.toLowerCase() === q.toLowerCase())) return x;
        return { ...x, annotation: { ...x.annotation, suggestions: [...cur, q] } };
      });
    }
    case 'answer':
      if (!exchangeId) return;
      return patchExchange(id, exchangeId, (x) => ({ ...x, answer: [...x.answer, e.text] }));
    case 'error':
      if (exchangeId) return patchExchange(id, exchangeId, (x) => ({ ...x, answer: [...x.answer, e.text] }));
      return patchCapture(id, (x) => ({ ...x, error: e.text }));
    case 'callout': {
      if (c.annotation.callouts.length >= MAX_CALLOUTS) return;
      const p = place(c, e.mark, e.at);
      if (!p) return;
      // Two labels on the same spot read as noise; keep the first.
      if (c.annotation.callouts.some((k) => dist(k.at, p.at) < 0.035)) return;
      const callout = { id: uid(), label: e.label, detail: e.detail, ...p };
      patchCapture(id, (x) => ({ ...x, annotation: { ...x.annotation, callouts: [...x.annotation.callouts, callout] } }));
      if (!callout.polygon) refine(id, 'callout', callout.id, callout.at);
      return;
    }
    case 'step': {
      const p = place(c, e.mark, e.at);
      const step: Step = { id: uid(), text: e.text, ...(p ?? {}) };
      if (exchangeId) {
        patchExchange(id, exchangeId, (x) => ({ ...x, steps: [...(x.steps ?? []), step] }));
      } else {
        patchCapture(id, (x) => ({ ...x, annotation: { ...x.annotation, steps: [...x.annotation.steps, step] } }));
      }
      if (p && !step.polygon) refine(id, 'step', step.id, p.at, exchangeId);
      return;
    }
  }
}

/**
 * Ask the segmenter (SAM on device, Vision otherwise) for the part under a
 * point and keep it only if it is a *part*: smaller than half the subject and
 * bigger than a speck. Runs one at a time per capture.
 */
const queues = new Map<string, Promise<void>>();
function refine(id: string, what: 'callout' | 'step', itemId: string, at: Pt, exchangeId?: string | null) {
  const prev = queues.get(id) ?? Promise.resolve();
  const next = prev.then(async () => {
    const c = getCapture(id);
    if (!c) return;
    let seg: Awaited<ReturnType<typeof LensiAR.segment>> = null;
    try {
      seg = await LensiAR.segment(c.media.stillUri, at.x, at.y);
    } catch {
      return;
    }
    if (!seg || seg.polygon.length < 3) return;
    const area = polygonArea(seg.polygon);
    const subjectArea = c.subject ? regionArea(c.subject) : 1;
    if (area < 0.0006 || area > Math.max(0.5 * subjectArea, 0.02)) return;
    const polygon = seg.polygon;
    if (what === 'callout') {
      patchCapture(id, (x) => ({
        ...x,
        annotation: {
          ...x.annotation,
          callouts: x.annotation.callouts.map((k) => (k.id === itemId ? { ...k, polygon } : k)),
        },
      }));
    } else if (exchangeId) {
      patchExchange(id, exchangeId, (x) => ({
        ...x,
        steps: (x.steps ?? []).map((s) => (s.id === itemId ? { ...s, polygon } : s)),
      }));
    } else {
      patchCapture(id, (x) => ({
        ...x,
        annotation: { ...x.annotation, steps: x.annotation.steps.map((s) => (s.id === itemId ? { ...s, polygon } : s)) },
      }));
    }
  });
  queues.set(id, next.catch(() => {}));
}

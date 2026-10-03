import { useCallback, useEffect, useReducer, useRef, type RefObject } from 'react';

import { LensiAR, type GuideChangeEvent, type GuideFrame } from '../../modules/lensi-ar/src';
import type { CameraHandle } from '../components/camera/CameraSurface';
import { pickEngine, visionEngine } from './engines';
import { currentStep, guideReducer, initialGuide, parseCommand, type GuideCommand, type GuideState } from './guide';
import { hush, say } from './narrate';
import { anchorFor, buildRegions, type AnalysisLike } from './regions';
import { getSettings } from './settings';
import type { EngineEvent, EngineRequest, Region } from './types';

/** After a check says "done", this long before moving on (so it can be heard). */
const ADVANCE_MS = 1600;

/**
 * The live guide session: the frame a plan was made from, the brain, the tags,
 * the change watch and the voice, around the pure reducer in guide.ts.
 */
export function useGuide(camera: RefObject<CameraHandle | null>, opts: { enabled: boolean }) {
  const [state, dispatch] = useReducer(guideReducer, initialGuide);
  const latest = useRef<GuideState>(state);
  latest.current = state;
  const frame = useRef<GuideFrame | null>(null);
  /** Every look this job took (the plan's, and any a question took), by frame id. */
  const looks = useRef(new Map<string, GuideFrame>());
  const pinned = useRef(new Set<string>());
  /** Parts whose shape was asked for (SAM at the part's point) or sent to the camera. */
  const shaped = useRef(new Set<string>());
  const drawn = useRef(new Set<string>());
  const work = useRef<AbortController | null>(null);
  const advance = useRef<ReturnType<typeof setTimeout> | null>(null);

  const speak = useCallback((text: string) => {
    if (getSettings().narrate && text) void say(text);
  }, []);

  const cancelWork = useCallback(() => {
    work.current?.abort();
    work.current = null;
    if (advance.current) clearTimeout(advance.current);
    advance.current = null;
  }, []);

  /** Run the brain once over a fresh frame; resolves with what it said, or null if cancelled. */
  const runBrain = useCallback(
    async (f: GuideFrame, req: Omit<EngineRequest, 'imageUri' | 'width' | 'height' | 'lens'>, onEvent: (e: EngineEvent) => void) => {
      const controller = new AbortController();
      work.current?.abort();
      work.current = controller;
      const engine = await pickEngine(getSettings().brain);
      await engine.run({ imageUri: f.uri, width: f.width, height: f.height, lens: 'guide', ...req }, onEvent, controller.signal);
      if (controller.signal.aborted) return false;
      if (work.current === controller) work.current = null;
      return true;
    },
    [],
  );

  const capture = useCallback(async () => {
    try {
      return (await camera.current?.guide.capture()) ?? null;
    } catch {
      return null;
    }
  }, [camera]);

  /** Start a job: say what you're doing; the plan, tags and first step follow. */
  const start = useCallback(
    async (task: string) => {
      const text = task.trim();
      if (!text) return;
      cancelWork();
      hush();
      pinned.current.clear();
      shaped.current.clear();
      drawn.current.clear();
      await camera.current?.guide.clear().catch(() => {});
      dispatch({ type: 'plan', task: text });
      const f = await capture();
      if (!f) {
        dispatch({ type: 'reset' });
        dispatch({ type: 'note', note: { text: "The camera isn't ready yet. Try again in a second.", tone: 'warn' } });
        return;
      }
      frame.current = f;
      looks.current = new Map([[f.frameId, f]]);
      let regions: Region[] = [];
      let hint: string | null = null;
      try {
        const built = buildRegions((await LensiAR.analyze(f.uri)) as AnalysisLike);
        regions = built.regions;
        hint = built.subject?.text ?? null;
      } catch {}
      let noModel: string | null = null;
      try {
        const ok = await runBrain(f, { regions, hint, question: text, walkthrough: true, guide: true }, (e) => {
          const region = 'mark' in e && e.mark ? regions.find((r) => r.mark === e.mark) : undefined;
          const at = region ? anchorFor(region) : 'at' in e ? e.at : undefined;
          const outline = region?.polygon;
          if (e.kind === 'title') dispatch({ type: 'title', text: e.text });
          else if (e.kind === 'step') {
            const label = e.label ?? (region?.kind === 'object' || region?.kind === 'text' ? region.text : undefined);
            dispatch({ type: 'step', text: e.text, label, at, mark: region?.mark, outline });
          } else if (e.kind === 'callout' && at) dispatch({ type: 'part', label: e.label, at, mark: region?.mark, outline });
          // Eyes only: the summary says why there are no steps.
          else if (e.kind === 'summary') noModel = e.text;
          else if (e.kind === 'error') dispatch({ type: 'note', note: { text: e.text, tone: 'warn' } });
        });
        if (!ok) return;
      } catch {
        dispatch({ type: 'note', note: { text: "Couldn't plan that one. Try saying it another way.", tone: 'warn' } });
      }
      // The model failed outright (a VM, assets missing): the eyes still tag the parts.
      if (!latest.current.steps.length && !latest.current.parts.length && !work.current) {
        try {
          await visionEngine.run(
            { imageUri: f.uri, width: f.width, height: f.height, lens: 'guide', regions, hint, question: text, walkthrough: true, guide: true },
            (e) => {
              const region = 'mark' in e && e.mark ? regions.find((r) => r.mark === e.mark) : undefined;
              const at = region ? anchorFor(region) : 'at' in e ? e.at : undefined;
              if (e.kind === 'callout' && at) dispatch({ type: 'part', label: e.label, at, mark: region?.mark, outline: region?.polygon });
              else if (e.kind === 'title') dispatch({ type: 'title', text: e.text });
              else if (e.kind === 'summary') noModel = e.text;
            },
            new AbortController().signal,
          );
        } catch {}
      }
      dispatch({ type: 'planned' });
      if (noModel && !latest.current.steps.length) {
        const tagged = latest.current.parts.length > 0;
        dispatch({
          type: 'note',
          note: {
            text: `Step-by-step help needs Apple Intelligence or the Lensi server. ${tagged ? 'The tags show what the phone found.' : 'The phone found nothing here it can name.'}`,
            tone: 'info',
          },
        });
      }
    },
    [camera, cancelWork, capture, runBrain],
  );

  /** Ask whether the current step is done, from a fresh look. */
  const check = useCallback(async () => {
    const s = latest.current;
    const { step } = currentStep(s);
    if (!step || s.status !== 'active') return;
    dispatch({ type: 'checking' });
    const f = await capture();
    if (!f) {
      dispatch({ type: 'checked', done: null, text: "Couldn't get a look just now." });
      return;
    }
    let verdict: { done: boolean | null; text: string } | null = null;
    try {
      const ok = await runBrain(f, { regions: [], hint: null, check: step.text }, (e) => {
        if (e.kind === 'check') verdict = { done: e.done, text: e.text };
        else if (e.kind === 'error' && !verdict) verdict = { done: null, text: e.text };
      });
      if (!ok) return;
    } catch {}
    const v: { done: boolean | null; text: string } = verdict ?? { done: null, text: "Couldn't tell from here." };
    dispatch({ type: 'checked', done: v.done, text: v.text });
    speak(v.text);
    if (v.done === true) {
      const at = latest.current.index;
      advance.current = setTimeout(() => {
        advance.current = null;
        // Only if they haven't moved on themselves meanwhile.
        if (latest.current.index === at && latest.current.status === 'active') dispatch({ type: 'next' });
      }, ADVANCE_MS);
    }
  }, [capture, runBrain, speak]);

  /** A question in the middle of a job, answered from a fresh look. */
  const ask = useCallback(
    async (question: string) => {
      const s = latest.current;
      if (s.status === 'idle' || s.status === 'planning') {
        await start(question);
        return;
      }
      dispatch({ type: 'answering' });
      const f = await capture();
      if (!f) {
        dispatch({ type: 'note', note: { text: "Couldn't get a look just now.", tone: 'warn' } });
        return;
      }
      const { step } = currentStep(s);
      const context = step ? ` (They are on this step: ${step.text})` : '';
      // The eyes look too, so an answer can point: "where's the valve?" tags it
      // where it is now, and a step that had nothing to point at gets it.
      looks.current.set(f.frameId, f);
      let regions: Region[] = [];
      try {
        regions = buildRegions((await LensiAR.analyze(f.uri)) as AnalysisLike).regions;
      } catch {}
      const lines: string[] = [];
      try {
        const ok = await runBrain(f, { regions, hint: s.title, question: `${question}${context}` }, (e) => {
          if (e.kind === 'answer' || e.kind === 'error') lines.push(e.text);
          else if (e.kind === 'callout') {
            const region = e.mark ? regions.find((r) => r.mark === e.mark) : undefined;
            const at = region ? anchorFor(region) : e.at;
            if (at) dispatch({ type: 'part', label: e.label, at, mark: region?.mark, outline: region?.polygon, frame: f.frameId, step: s.index });
          }
        });
        if (!ok) return;
      } catch {}
      const text = lines.join(' ') || "Couldn't answer that one.";
      dispatch({ type: 'note', note: { text, tone: 'info' } });
      speak(text);
    },
    [capture, runBrain, speak, start],
  );

  // Moving on means nothing until there's a plan, and must not cancel the one being made.
  const next = useCallback(() => {
    if (latest.current.status === 'idle' || latest.current.status === 'planning') return;
    cancelWork();
    dispatch({ type: 'next' });
  }, [cancelWork]);
  const back = useCallback(() => {
    if (latest.current.status === 'idle' || latest.current.status === 'planning') return;
    cancelWork();
    dispatch({ type: 'back' });
  }, [cancelWork]);
  const repeat = useCallback(() => {
    const { step } = currentStep(latest.current);
    if (step) void say(step.text);
  }, []);
  const stop = useCallback(() => {
    cancelWork();
    hush();
    pinned.current.clear();
    shaped.current.clear();
    drawn.current.clear();
    frame.current = null;
    looks.current = new Map();
    void camera.current?.guide.clear().catch(() => {});
    dispatch({ type: 'reset' });
  }, [camera, cancelWork]);

  /** Whatever was said or typed (or already read as a command): a command, a question, or a new job. */
  const handle = useCallback(
    (input: string | GuideCommand) => {
      const cmd = typeof input === 'string' ? parseCommand(input) : input;
      if (!cmd) return;
      const s = latest.current;
      if (cmd.type === 'ask') {
        void (s.status === 'finished' ? start(cmd.text) : ask(cmd.text));
        return;
      }
      if (cmd.type === 'next') next();
      else if (cmd.type === 'back') back();
      else if (cmd.type === 'repeat') repeat();
      else if (cmd.type === 'check') void check();
      else if (cmd.type === 'stop') stop();
      // 'mute' is the screen's: it owns the hands-free mic.
    },
    [ask, back, check, next, repeat, start, stop],
  );

  // Tags: pin each new part in the world, in the look it was found in.
  useEffect(() => {
    const f = frame.current;
    if (!f) return;
    for (const p of state.parts) {
      if (pinned.current.has(p.id)) continue;
      pinned.current.add(p.id);
      void camera.current?.guide.pin(p.frame ?? f.frameId, p).catch(() => {});
    }
  }, [state.parts, camera]);

  // Each part's shape: SAM at its point when the eyes didn't already outline it.
  // (A shape that covers half the frame is the whole scene, not a part.)
  useEffect(() => {
    const f = frame.current;
    if (!f) return;
    for (const p of state.parts) {
      if (p.outline || shaped.current.has(p.id)) continue;
      shaped.current.add(p.id);
      const look = (p.frame && looks.current.get(p.frame)) || f;
      void LensiAR.segment(look.uri, p.at.x, p.at.y)
        .then((seg) => {
          // Still this job (part ids repeat from one job to the next).
          if (!seg || frame.current !== f || seg.box.w * seg.box.h > 0.5) return;
          dispatch({ type: 'outline', id: p.id, outline: seg.polygon });
        })
        .catch(() => {});
    }
  }, [state.parts]);
  // ...and on the camera, laid on the part in the world.
  useEffect(() => {
    const f = frame.current;
    if (!f) return;
    for (const p of state.parts) {
      if (!p.outline || drawn.current.has(p.id) || !pinned.current.has(p.id)) continue;
      drawn.current.add(p.id);
      void camera.current?.guide.outline(p.frame ?? f.frameId, p.id, p.outline).catch(() => {});
    }
  }, [state.parts, camera]);

  // The current step's part stands out, and it's the one watched for a change.
  const { step, part } = currentStep(state);
  const watching = opts.enabled && state.status === 'active' && !!part;
  useEffect(() => {
    void camera.current?.guide.focus(state.status === 'idle' ? null : (part?.id ?? null)).catch(() => {});
  }, [camera, part?.id, state.status]);
  useEffect(() => {
    void camera.current?.guide.watch(watching ? (part?.id ?? null) : null).catch(() => {});
  }, [camera, watching, part?.id]);

  // Each new step is read out once.
  const spoken = useRef<string>('');
  useEffect(() => {
    if (state.status !== 'active' || !step) return;
    const key = `${state.task}#${state.index}`;
    if (spoken.current === key) return;
    spoken.current = key;
    speak(`Step ${state.index + 1}. ${step.text}`);
  }, [state.status, state.index, state.task, step, speak]);
  useEffect(() => {
    if (state.status === 'finished') speak('All done.');
  }, [state.status, speak]);

  // Leaving the guide (another lens, a capture on top) stops the work and the watch.
  useEffect(() => {
    if (!opts.enabled) {
      cancelWork();
      void camera.current?.guide.watch(null).catch(() => {});
    }
  }, [opts.enabled, camera, cancelWork]);

  const onChange = useCallback(
    (_e: GuideChangeEvent) => {
      if (latest.current.status === 'active') void check();
    },
    [check],
  );

  return { state, step, part, watching, start, ask, check, next, back, repeat, stop, handle, onChange };
}

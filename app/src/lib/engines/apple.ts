import { LensiAR } from '../../../modules/lensi-ar/src';
import type { Engine, EngineEvent, Pt } from '../types';

let seq = 0;
/**
 * When the model fails outright (assets missing, a VM, a model update in
 * progress) it tends to keep failing; skip it for a while so the next capture
 * goes straight to the cloud or the eyes instead of hitting the same error.
 */
let brokenUntil = 0;
const COOLDOWN_MS = 5 * 60 * 1000;
/**
 * The model streams a field at a time, so this long with nothing new means it
 * has stalled (or is still loading). Give up and let the eyes fill in rather
 * than leave the capture thinking forever.
 */
const STALL_MS = 30 * 1000;

function toEvent(raw: Record<string, unknown>): EngineEvent | null {
  const kind = raw.kind;
  const text = typeof raw.text === 'string' ? raw.text.trim() : '';
  const label = typeof raw.label === 'string' ? raw.label.trim() : '';
  const mark = typeof raw.mark === 'number' && raw.mark >= 1 ? Math.round(raw.mark) : undefined;
  const at =
    raw.at && typeof raw.at === 'object' && typeof (raw.at as Pt).x === 'number' && typeof (raw.at as Pt).y === 'number'
      ? (raw.at as Pt)
      : undefined;
  switch (kind) {
    case 'title':
    case 'summary':
    case 'fact':
    case 'answer':
    case 'suggest':
    case 'error':
      return text ? { kind, text } : null;
    case 'callout':
      return label ? { kind, label, mark, at, detail: typeof raw.detail === 'string' ? raw.detail : undefined } : null;
    case 'step':
      return text ? { kind, text, mark, at } : null;
    default:
      return null;
  }
}

/**
 * Apple's on-device Foundation Model (iOS 27 takes the photo itself as an
 * image attachment). The Swift side draws numbered marks on the photo and
 * the model answers in marks, so every label lands on something real.
 */
export const appleEngine: Engine = {
  id: 'apple',
  name: 'Apple Intelligence',

  async available() {
    if (Date.now() < brokenUntil) return false;
    try {
      return (await LensiAR.intelligenceStatus()).available;
    } catch {
      return false;
    }
  },

  run(req, emit, signal) {
    const requestId = `fm${Date.now().toString(36)}${(seq++).toString(36)}`;
    return new Promise<void>((resolve) => {
      let finished = false;
      let stall: ReturnType<typeof setTimeout> | undefined;
      const finish = () => {
        if (finished) return;
        finished = true;
        clearTimeout(stall);
        sub.remove();
        resolve();
      };
      const watch = () => {
        clearTimeout(stall);
        stall = setTimeout(() => {
          void Promise.resolve(LensiAR.intelligenceCancel(requestId)).catch(() => {});
          emit({ kind: 'error', text: 'Apple Intelligence took too long to answer.' });
          finish();
        }, STALL_MS);
      };
      const sub = LensiAR.addListener('onIntelligence', (e) => {
        if (e.requestId !== requestId) return;
        watch();
        if (e.type === 'event') {
          const ev = toEvent(e.event);
          if (ev) emit(ev);
        } else if (e.type === 'error') {
          if (e.unavailable) brokenUntil = Date.now() + COOLDOWN_MS;
          emit({ kind: 'error', text: e.message || 'Apple Intelligence stopped.' });
          finish();
        } else {
          finish();
        }
      });
      signal.addEventListener('abort', () => {
        void Promise.resolve(LensiAR.intelligenceCancel(requestId)).catch(() => {});
        finish();
      });
      const payload = {
        imageUri: req.imageUri,
        lens: req.lens,
        hint: req.hint,
        question: req.question ?? null,
        walkthrough: req.walkthrough ?? false,
        history: req.history ?? [],
        marks: req.regions.map((r) => ({ mark: r.mark, kind: r.kind, text: r.text ?? null, box: r.box })),
      };
      watch();
      LensiAR.intelligenceStart(requestId, JSON.stringify(payload)).catch((err: unknown) => {
        emit({ kind: 'error', text: err instanceof Error ? err.message : 'Apple Intelligence is unavailable.' });
        finish();
      });
    });
  },
};

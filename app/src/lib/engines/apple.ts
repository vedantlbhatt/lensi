import { LensiAR } from '../../../modules/lensi-ar/src';
import type { Engine, EngineEvent, Pt } from '../types';

let seq = 0;

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
      const finish = () => {
        if (finished) return;
        finished = true;
        sub.remove();
        resolve();
      };
      const sub = LensiAR.addListener('onIntelligence', (e) => {
        if (e.requestId !== requestId) return;
        if (e.type === 'event') {
          const ev = toEvent(e.event);
          if (ev) emit(ev);
        } else if (e.type === 'error') {
          emit({ kind: 'error', text: e.message || 'Apple Intelligence stopped.' });
          finish();
        } else {
          finish();
        }
      });
      signal.addEventListener('abort', () => {
        LensiAR.intelligenceCancel(requestId);
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
      LensiAR.intelligenceStart(requestId, JSON.stringify(payload)).catch((err: unknown) => {
        emit({ kind: 'error', text: err instanceof Error ? err.message : 'Apple Intelligence is unavailable.' });
        finish();
      });
    });
  },
};

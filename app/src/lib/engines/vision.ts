import type { Engine, EngineEvent, Region } from '../types';

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);

/**
 * No model at all: say only what the on-device eyes actually found. Always
 * available, instant, and honest about being limited.
 */
export const visionEngine: Engine = {
  id: 'vision',
  name: 'On-device vision',

  async available() {
    return true;
  },

  async run(req, emit) {
    const out: EngineEvent[] = [];
    const subject = req.regions.find((r) => r.kind === 'subject');
    const texts = req.regions.filter((r) => r.kind === 'text');
    const codes = req.regions.filter((r) => r.kind === 'barcode');
    const objects = req.regions.filter((r) => r.kind === 'object' && r.text);

    if (req.question || req.walkthrough) {
      out.push({
        kind: 'answer',
        text: 'Answers and walkthroughs need Apple Intelligence or the cloud brain. Turn one on in Settings.',
      });
    } else {
      const name = subject?.text ?? req.hint ?? objects[0]?.text;
      out.push({ kind: 'title', text: name ? cap(name) : texts[0]?.text ? clip(texts[0].text!, 28) : 'Something here' });
      const n = (k: number, one: string, many: string) => `${k} ${k === 1 ? one : many}`;
      const bits: string[] = [];
      if (texts.length) bits.push(`read ${n(texts.length, 'line of text', 'lines of text')}`);
      if (codes.length) bits.push(`found ${n(codes.length, 'code', 'codes')}`);
      if (objects.length) bits.push(`spotted ${n(objects.length, 'other thing', 'other things')}`);
      const said = bits.length > 1 ? `${bits.slice(0, -1).join(', ')} and ${bits[bits.length - 1]}` : bits[0];
      out.push({
        kind: 'summary',
        text: said ? `${cap(said)}, all on this phone.` : 'Outlined on this phone. Names and answers need Apple Intelligence.',
      });
      const callouts: Region[] = [...codes, ...texts.slice(0, 4), ...objects.slice(0, 2)];
      for (const r of callouts) out.push({ kind: 'callout', label: clip(r.text ?? r.kind, 26), mark: r.mark });
      for (const c of codes) out.push({ kind: 'fact', text: `Code reads ${clip(c.text ?? '', 60)}` });
      if (texts.length) out.push({ kind: 'fact', text: `Text: ${texts.slice(0, 3).map((t) => `“${clip(t.text ?? '', 30)}”`).join(', ')}` });
      const things = [...new Set(objects.map((o) => o.text!).filter((t) => t && t !== name))];
      if (things.length) out.push({ kind: 'fact', text: `Also here: ${things.slice(0, 4).join(', ')}` });
    }
    for (const e of out) {
      emit(e);
      await new Promise((r) => setTimeout(r, 90));
    }
  },
};

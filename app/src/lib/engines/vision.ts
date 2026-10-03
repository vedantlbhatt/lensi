import { codeLabel, readCode } from '../codes';
import type { Engine, EngineEvent, Region } from '../types';

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);

/** The detector's class names that don't just take an s. */
const PLURALS: Record<string, string> = {
  person: 'people',
  mouse: 'mice',
  knife: 'knives',
  sheep: 'sheep',
  skis: 'skis',
  broccoli: 'broccoli',
  tv: 'TVs',
};
const DISPLAY: Record<string, string> = { tv: 'TV' };
const WORDS = ['no', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];
const num = (n: number) => (n < WORDS.length ? WORDS[n] : String(n));

/** "a truck", "an orange", "two cars", "12 people". */
export function counted(word: string, n: number): string {
  const w = word.trim().toLowerCase();
  if (n === 1) return `${/^[aeiou]/.test(w) ? 'an' : 'a'} ${DISPLAY[w] ?? w}`;
  const many = PLURALS[w] ?? (/(s|x|z|ch|sh)$/.test(w) ? `${w}es` : `${w}s`);
  return `${num(n)} ${many}`;
}

const and = (parts: string[]) => (parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}` : (parts[0] ?? ''));

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

    if (req.question && !req.walkthrough) {
      out.push({
        kind: 'answer',
        text: 'Answers and walkthroughs need Apple Intelligence or the cloud brain. Turn one on in Settings.',
      });
    } else {
      const name = subject?.text ?? req.hint ?? objects[0]?.text;
      out.push({ kind: 'title', text: name ? cap(name) : texts[0]?.text ? clip(texts[0].text!, 28) : 'Something here' });
      // What was found, by name and count, most common first: "two oranges and a lemon".
      const tally = new Map<string, number>();
      for (const t of [subject?.text, ...objects.map((o) => o.text)]) {
        const k = t?.trim().toLowerCase();
        if (k) tally.set(k, (tally.get(k) ?? 0) + 1);
      }
      const things = [...tally].sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, c]) => counted(k, c));
      const bits: string[] = [];
      if (things.length) bits.push(`spotted ${and(things)}`);
      if (texts.length) bits.push(`read ${texts.length === 1 ? 'a line' : `${num(texts.length)} lines`} of text`);
      if (codes.length) bits.push(`found ${counted('code', codes.length)}`);
      const said = and(bits);
      out.push({
        kind: 'summary',
        text: req.walkthrough
          ? 'Walkthroughs need Apple Intelligence or the cloud brain. Here is what the phone found.'
          : said
            ? `${cap(said)}, all on this phone.`
            : 'Outlined on this phone. Names and answers need Apple Intelligence.',
      });
      const callouts: Region[] = [...codes, ...texts.slice(0, 4), ...objects.slice(0, 4)].slice(0, 7);
      for (const r of callouts) {
        const label = r.kind === 'barcode' && r.text ? codeLabel(r.text) : r.kind === 'object' && r.text ? cap(DISPLAY[r.text] ?? r.text) : (r.text ?? r.kind);
        out.push({ kind: 'callout', label: clip(label, 26), mark: r.mark });
      }
      for (const c of codes) {
        const m = readCode(c.text ?? '');
        out.push({
          kind: 'fact',
          text:
            m.kind === 'url'
              ? `Code links to ${m.host}. Hold its label to open it.`
              : m.kind === 'wifi'
                ? `Wi-Fi network “${m.ssid}”${m.password ? '. Hold its label to copy the password.' : ', no password.'}`
                : `Code reads ${clip(m.text, 60)}`,
        });
      }
      if (texts.length) out.push({ kind: 'fact', text: `Text: ${texts.slice(0, 3).map((t) => `“${clip(t.text ?? '', 30)}”`).join(', ')}` });
    }
    for (const e of out) {
      emit(e);
      await new Promise((r) => setTimeout(r, 90));
    }
  },
};

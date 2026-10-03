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

const area = (r: Region) => r.box.w * r.box.h;
const overlap = (a: Region, b: Region) => {
  const w = Math.min(a.box.x + a.box.w, b.box.x + b.box.w) - Math.max(a.box.x, b.box.x);
  const h = Math.min(a.box.y + a.box.h, b.box.y + b.box.h) - Math.max(a.box.y, b.box.y);
  return w > 0 && h > 0 ? (w * h) / Math.max(1e-9, Math.min(area(a), area(b))) : 0;
};
const contains = (r: Region, x: number, y: number) => x >= r.box.x && x <= r.box.x + r.box.w && y >= r.box.y && y <= r.box.y + r.box.h;

/**
 * A tapped part, answered from what the eyes found there: the text or code it
 * carries, or the detected thing it belongs to. Never a guess at a name.
 */
export function tapAnswer(part: Region, regions: Region[]): EngineEvent[] {
  const others = regions.filter((r) => r.id !== part.id);
  const code = others.find((r) => r.kind === 'barcode' && r.text && overlap(r, part) > 0.5);
  if (code?.text) {
    const m = readCode(code.text);
    const said = m.kind === 'url' ? `A code that links to ${m.host}.` : m.kind === 'wifi' ? `A Wi-Fi code for “${m.ssid}”.` : `A code that reads “${clip(m.text, 60)}”.`;
    return [
      { kind: 'answer', text: said },
      { kind: 'callout', label: clip(codeLabel(code.text), 26), mark: part.mark },
    ];
  }
  const text = others.filter((r) => r.kind === 'text' && r.text && overlap(r, part) > 0.5);
  if (text.length) {
    const read = text.map((t) => t.text!.trim()).join(' ');
    return [
      { kind: 'answer', text: `It reads “${clip(read, 80)}”.` },
      { kind: 'callout', label: clip(read, 26), mark: part.mark },
    ];
  }
  const cx = part.box.x + part.box.w / 2;
  const cy = part.box.y + part.box.h / 2;
  const thing = others
    .filter((r) => (r.kind === 'object' || r.kind === 'subject') && r.text && contains(r, cx, cy))
    .sort((a, b) => area(a) - area(b))[0];
  if (thing?.text) {
    // About the size of the thing itself: that's what it is. Much smaller: a part of it.
    if (area(part) > area(thing) * 0.5) {
      return [
        { kind: 'answer', text: `That's ${counted(thing.text, 1)}, going by the detector on this phone.` },
        { kind: 'callout', label: cap(DISPLAY[thing.text] ?? thing.text), mark: part.mark },
      ];
    }
    return [{ kind: 'answer', text: `Part of the ${thing.text.toLowerCase()}, outlined on this phone. Naming the part itself needs Apple Intelligence.` }];
  }
  return [{ kind: 'answer', text: 'Outlined on this phone. Naming it needs Apple Intelligence.' }];
}

const and = (parts: string[]) => (parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}` : (parts[0] ?? ''));

/** "people" → "person", "bottles" → "bottle": a word from a question, as the detector names it. */
function singular(word: string): string {
  const w = word.toLowerCase();
  const irregular = Object.entries(PLURALS).find(([, many]) => many.toLowerCase() === w);
  if (irregular) return irregular[0];
  if (/(ches|shes|sses|xes|zes)$/.test(w)) return w.slice(0, -2);
  return w.endsWith('s') ? w.slice(0, -1) : w;
}

/**
 * A typed or spoken question the eyes can answer from what they found: how many
 * of something, what the text says, where a code goes. Null when it needs a model.
 */
export function factAnswer(question: string, regions: Region[]): string | null {
  const q = question.toLowerCase();
  const texts = regions.filter((r) => r.kind === 'text' && r.text);
  const codes = regions.filter((r) => r.kind === 'barcode' && r.text);
  const howMany = /how many ([a-z][a-z -]*?)s?\b(?:\s+(?:are|is|do|can|in|on|here|there)\b|\?|$)/.exec(q);
  if (howMany) {
    const asked = singular(howMany[1].trim().split(/\s+/).pop() ?? '');
    const n = regions.filter((r) => (r.kind === 'object' || r.kind === 'subject') && r.text?.toLowerCase() === asked).length;
    if (n) return `${cap(num(n))}, going by the detector on this phone.`;
    return `None that the detector recognised. Counting anything else needs Apple Intelligence.`;
  }
  if (/\b(qr|code|link|url|wi-?fi|password)\b/.test(q) && codes.length) {
    const m = readCode(codes[0].text!);
    return m.kind === 'url'
      ? `The code links to ${m.host}. Hold its label to open it.`
      : m.kind === 'wifi'
        ? `It's a Wi-Fi code for “${m.ssid}”.${m.password ? ' Hold its label to copy the password.' : ''}`
        : `The code reads “${clip(m.text, 80)}”.`;
  }
  if (/\b(say|says|read|reads|written|text|label|sign|word|words)\b/.test(q)) {
    if (!texts.length) return 'There is no text here the phone could read.';
    const lines = texts.slice(0, 6).map((t) => `“${clip(t.text!.trim(), 40)}”`);
    return `It reads ${and(lines)}.`;
  }
  return null;
}

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

    // A tap on the print arrives as a question about one mark.
    const tapped = req.question ? /mark (\d+)/.exec(req.question)?.[1] : undefined;
    const part = tapped ? req.regions.find((r) => r.mark === Number(tapped)) : undefined;
    if (req.question && !req.walkthrough && part) {
      out.push(...tapAnswer(part, req.regions));
    } else if (req.question && !req.walkthrough) {
      out.push({
        kind: 'answer',
        text: factAnswer(req.question, req.regions) ?? 'Answers and walkthroughs need Apple Intelligence or the cloud brain. Turn one on in Settings.',
      });
    } else {
      // What was found, by name and count, most common first: "two oranges and a lemon".
      const tally = new Map<string, number>();
      for (const t of [subject?.text, ...objects.map((o) => o.text)]) {
        const k = t?.trim().toLowerCase();
        if (k) tally.set(k, (tally.get(k) ?? 0) + 1);
      }
      const name = subject?.text ?? req.hint ?? objects[0]?.text;
      // Four people in a room are "Four people", not "Person".
      const many = name ? (tally.get(name.trim().toLowerCase()) ?? 0) : 0;
      // No name for it: a line or two of text can stand as the title; more reads as a count.
      const title = name
        ? cap(many > 1 ? counted(name, many) : name)
        : texts.length > 2
          ? `${cap(num(texts.length))} lines of text`
          : texts[0]?.text
            ? clip(texts[0].text, 28)
            : 'Something here';
      out.push({ kind: 'title', text: title });
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

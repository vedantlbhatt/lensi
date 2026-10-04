// The cloud model streams one instruction per line (see server/src/prompt.ts).
// Each complete line is applied the moment it arrives, so the title and the
// first callouts land while the rest of the answer is still generating.
//
//   T|title                      S|summary sentence          F|fact
//   P|x|y|label   callout at a point, x/y integers 0-1000 from the top-left
//   M|n|label     callout on numbered mark n
//   W|x|y|text    walkthrough step pointing at a point
//   N|n|text      walkthrough step pointing at mark n
//   W|text        walkthrough step with nothing to point at
//   G|x|y|part|text   live-guide step at a point, with its part in 1-3 words
//   G|n|part|text     live-guide step on mark n
//   G|text            live-guide step with nothing to point at
//   C|yes|seen    C|no|what to do now    C|unsure|why   a step checked against the photo
//   A|sentence    answer to a follow-up question
//   Q|question    a follow-up the user is likely to ask next
//   E|message     error to show

import type { EngineEvent } from './types';

const clamp01 = (v: number) => Math.min(1, Math.max(0, v / 1000));

function num(s: string | undefined): number | null {
  if (s === undefined || s.trim() === '') return null;
  const v = Number(s.trim().replace(/^#/, ''));
  return Number.isFinite(v) ? v : null;
}

export function parseLine(raw: string): EngineEvent | null {
  const line = raw.trim();
  const bar = line.indexOf('|');
  if (bar < 1) return null;
  const tag = line.slice(0, bar).trim().toUpperCase();
  const rest = line.slice(bar + 1).trim();
  if (!rest) return null;
  switch (tag) {
    case 'T':
      return { kind: 'title', text: rest };
    case 'S':
      return { kind: 'summary', text: rest };
    case 'F':
      return { kind: 'fact', text: rest };
    case 'A':
      return { kind: 'answer', text: rest };
    case 'Q':
      return { kind: 'suggest', text: rest };
    case 'E':
      return { kind: 'error', text: rest };
    case 'P': {
      const [xs, ys, ...label] = rest.split('|');
      const x = num(xs);
      const y = num(ys);
      const text = label.join(' ').trim();
      if (x === null || y === null || !text) return null;
      return { kind: 'callout', label: text, at: { x: clamp01(x), y: clamp01(y) } };
    }
    case 'M': {
      const [ms, ...label] = rest.split('|');
      const mark = num(ms);
      const text = label.join(' ').trim();
      if (mark === null || mark < 1 || !text) return null;
      return { kind: 'callout', label: text, mark: Math.round(mark) };
    }
    case 'N': {
      const [ms, ...words] = rest.split('|');
      const mark = num(ms);
      const text = words.join(' ').trim();
      if (mark === null || !text) return null;
      return mark >= 1 ? { kind: 'step', text, mark: Math.round(mark) } : { kind: 'step', text };
    }
    case 'W': {
      const parts = rest.split('|');
      if (parts.length >= 3) {
        const x = num(parts[0]);
        const y = num(parts[1]);
        const text = parts.slice(2).join(' ').trim();
        if (x !== null && y !== null && text) return { kind: 'step', text, at: { x: clamp01(x), y: clamp01(y) } };
      }
      const text = parts.join(' ').trim();
      return text ? { kind: 'step', text } : null;
    }
    case 'G': {
      const parts = rest.split('|').map((p) => p.trim());
      if (parts.length >= 4) {
        const x = num(parts[0]);
        const y = num(parts[1]);
        const text = parts.slice(3).join(' ').trim();
        if (x !== null && y !== null && text) {
          return { kind: 'step', text, at: { x: clamp01(x), y: clamp01(y) }, ...(parts[2] ? { label: parts[2] } : {}) };
        }
      }
      if (parts.length === 3) {
        const mark = num(parts[0]);
        if (mark !== null && parts[2]) {
          const step = { kind: 'step' as const, text: parts[2], ...(parts[1] ? { label: parts[1] } : {}) };
          return mark >= 1 ? { ...step, mark: Math.round(mark) } : step;
        }
      }
      const text = parts.join(' ').trim();
      return text ? { kind: 'step', text } : null;
    }
    case 'C': {
      const [verdict, ...words] = rest.split('|');
      const v = verdict.trim().toLowerCase();
      const text = words.join(' ').trim();
      if (!text) return null;
      return { kind: 'check', done: v === 'yes' ? true : v === 'no' ? false : null, text };
    }
    default:
      return null;
  }
}

/** Splits a chunked text stream into lines, holding back the partial tail. */
export class LineSplitter {
  private buffer = '';

  push(chunk: string): string[] {
    this.buffer += chunk;
    const parts = this.buffer.split('\n');
    this.buffer = parts.pop() ?? '';
    return parts;
  }

  flush(): string[] {
    const rest = this.buffer;
    this.buffer = '';
    return rest.trim() ? [rest] : [];
  }
}

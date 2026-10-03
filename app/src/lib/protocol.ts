// Claude streams one instruction per line (see server/src/prompt.ts). Each
// complete line is applied the moment it arrives so the pin title and callouts
// land while the rest of the answer is still generating.

export type Line =
  | { kind: 'title'; text: string }
  | { kind: 'summary'; text: string }
  | { kind: 'point'; x: number; y: number; label: string }
  | { kind: 'fact'; text: string }
  | { kind: 'answer'; text: string }
  | { kind: 'error'; text: string };

export function parseLine(raw: string): Line | null {
  const line = raw.trim();
  const bar = line.indexOf('|');
  if (bar < 1) return null;
  const tag = line.slice(0, bar).toUpperCase();
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
    case 'E':
      return { kind: 'error', text: rest };
    case 'P': {
      const [xs, ys, ...label] = rest.split('|');
      const x = Number(xs);
      const y = Number(ys);
      const text = label.join(' ').trim();
      if (!Number.isFinite(x) || !Number.isFinite(y) || !text) return null;
      const clamp = (v: number) => Math.min(1, Math.max(0, v / 1000));
      return { kind: 'point', x: clamp(x), y: clamp(y), label: text };
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

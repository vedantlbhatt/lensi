/**
 * What a scanned code means, from its raw payload. QR codes wrap links and
 * Wi-Fi details in a few common formats; this reads the ones people point a
 * camera at (router stickers, posters, packaging).
 */
export type CodeMeaning =
  | { kind: 'url'; url: string; host: string }
  | { kind: 'wifi'; ssid: string; password: string | null }
  | { kind: 'text'; text: string };

/** Splits `KEY:value;KEY:value;` fields, honouring backslash escapes. */
function fields(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  let key = '';
  let val = '';
  let inVal = false;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === '\\' && i + 1 < body.length) {
      (inVal ? (val += body[++i]) : (key += body[++i]));
      continue;
    }
    if (!inVal && ch === ':') {
      inVal = true;
    } else if (inVal && ch === ';') {
      if (key) out[key.toUpperCase()] = val;
      key = '';
      val = '';
      inVal = false;
    } else if (inVal) {
      val += ch;
    } else {
      key += ch;
    }
  }
  if (inVal && key) out[key.toUpperCase()] = val;
  return out;
}

function asURL(s: string): { url: string; host: string } | null {
  const t = s.trim();
  const m = /^(https?):\/\/([^/\s?#]+)[^\s]*$/i.exec(t);
  return m ? { url: t, host: m[2].replace(/^www\./i, '') } : null;
}

export function readCode(payload: string): CodeMeaning {
  const raw = payload.trim();
  const plain = asURL(raw);
  if (plain) return { kind: 'url', ...plain };
  const upper = raw.toUpperCase();
  if (upper.startsWith('WIFI:')) {
    const f = fields(raw.slice(5));
    if (f.S) return { kind: 'wifi', ssid: f.S, password: f.P ? f.P : null };
  }
  if (upper.startsWith('MEBKM:')) {
    const u = asURL(fields(raw.slice(6)).URL ?? '');
    if (u) return { kind: 'url', ...u };
  }
  if (upper.startsWith('URLTO:') || upper.startsWith('URL:')) {
    const u = asURL(raw.slice(raw.indexOf(':') + 1));
    if (u) return { kind: 'url', ...u };
  }
  return { kind: 'text', text: raw };
}

/** A short label for the print: "Link · wikipedia.org", "Wi-Fi · HomeNet". */
export function codeLabel(payload: string): string {
  const m = readCode(payload);
  if (m.kind === 'url') return `Link · ${m.host}`;
  if (m.kind === 'wifi') return `Wi-Fi · ${m.ssid}`;
  return m.text;
}

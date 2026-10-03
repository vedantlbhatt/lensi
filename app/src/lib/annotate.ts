import Constants from 'expo-constants';
import { fetch } from 'expo/fetch';

import { LineSplitter, parseLine, type Line } from './protocol';

export type Lens = 'identify' | 'fix' | 'shop' | 'safe' | 'learn';

/**
 * EXPO_PUBLIC_LENSI_SERVER wins. In development we fall back to the machine
 * running Metro on port 8787, so `npm start` in server/ is all it takes.
 */
export function serverURL(): string {
  const fromEnv = process.env.EXPO_PUBLIC_LENSI_SERVER;
  if (fromEnv) return fromEnv.replace(/\/$/, '');
  const host = Constants.expoConfig?.hostUri?.split(':')[0];
  return `http://${host ?? 'localhost'}:8787`;
}

export async function streamAnnotation(
  req: { image: string; label: string | null; lens: Lens; question?: string },
  onLine: (line: Line) => void,
  signal: AbortSignal,
): Promise<void> {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  const token = process.env.EXPO_PUBLIC_LENSI_TOKEN;
  if (token) headers.authorization = `Bearer ${token}`;

  const res = await fetch(`${serverURL()}/annotate`, {
    method: 'POST',
    headers,
    body: JSON.stringify(req),
    signal,
  });
  if (!res.ok || !res.body) {
    onLine({ kind: 'error', text: res.status === 401 ? 'Server token mismatch.' : `Server error ${res.status}.` });
    return;
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  const splitter = new LineSplitter();
  const emit = (raw: string) => {
    const line = parseLine(raw);
    if (line) onLine(line);
  };
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    splitter.push(decoder.decode(value, { stream: true })).forEach(emit);
  }
  splitter.flush().forEach(emit);
}

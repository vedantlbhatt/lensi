import Constants from 'expo-constants';
import { fetch } from 'expo/fetch';
import { File } from 'expo-file-system';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import { Platform } from 'react-native';

import { LineSplitter, parseLine } from '../protocol';
import { describeMarks } from '../regions';
import { getSettings } from '../settings';
import type { Engine, EngineRequest } from '../types';

/**
 * Settings override → EXPO_PUBLIC_LENSI_SERVER → the machine running Metro on
 * port 8787, so `npm start` in server/ is all it takes in development.
 */
export function serverURL(): string {
  const fromSettings = getSettings().serverURL.trim();
  if (fromSettings) return fromSettings.replace(/\/$/, '');
  const fromEnv = process.env.EXPO_PUBLIC_LENSI_SERVER;
  if (fromEnv) return fromEnv.replace(/\/$/, '');
  const host = Constants.expoConfig?.hostUri?.split(':')[0];
  return `http://${host ?? 'localhost'}:8787`;
}

async function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([p, new Promise<T>((_, reject) => setTimeout(() => reject(new Error('timeout')), ms))]);
}

/** Longest side ≤ 1280 JPEG, base64. Big enough to read labels, small enough to send fast. */
async function encode(req: EngineRequest): Promise<string> {
  if (Platform.OS === 'web') {
    // expo-file-system can't read asset or blob URLs in a browser; the browser can.
    const blob = await (await globalThis.fetch(req.imageUri)).blob();
    return new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(',')[1] ?? '');
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
  }
  const longest = Math.max(req.width, req.height);
  if (longest > 1280) {
    const scale = 1280 / longest;
    const ref = await ImageManipulator.manipulate(req.imageUri)
      .resize({ width: Math.round(req.width * scale), height: Math.round(req.height * scale) })
      .renderAsync();
    const out = await ref.saveAsync({ compress: 0.78, format: SaveFormat.JPEG, base64: true });
    if (out.base64) return out.base64;
  }
  return new File(req.imageUri).base64();
}

let lastHealth: { at: number; ok: boolean } | null = null;
/** No bytes from the server for this long: it has stalled; stop so the eyes can fill in. */
const STALL_MS = 45 * 1000;

export const cloudEngine: Engine = {
  id: 'cloud',
  name: 'Claude',

  async available() {
    if (lastHealth && Date.now() - lastHealth.at < 15_000) return lastHealth.ok;
    let ok = false;
    try {
      const res = await withTimeout(fetch(`${serverURL()}/health`), 1500);
      ok = res.ok;
    } catch {
      ok = false;
    }
    lastHealth = { at: Date.now(), ok };
    return ok;
  },

  async run(req, emit, signal) {
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    const token = process.env.EXPO_PUBLIC_LENSI_TOKEN;
    if (token) headers.authorization = `Bearer ${token}`;

    const image = await encode(req);
    // Our own controller, so a stall can end the request without the caller aborting.
    const ctl = new AbortController();
    const stop = () => ctl.abort();
    signal.addEventListener('abort', stop);
    // Closed while the photo was still being encoded.
    if (signal.aborted) ctl.abort();
    let stalled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const watch = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        stalled = true;
        ctl.abort();
      }, STALL_MS);
    };
    try {
      watch();
      const res = await fetch(`${serverURL()}/annotate`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          image,
          label: req.hint,
          lens: req.lens,
          question: req.question,
          walkthrough: req.walkthrough ?? false,
          guide: req.guide ?? false,
          check: req.check,
          marks: describeMarks(req.regions),
          history: req.history ?? [],
        }),
        signal: ctl.signal,
      });
      if (!res.ok || !res.body) {
        emit({ kind: 'error', text: res.status === 401 ? 'Server token mismatch.' : `Server error ${res.status}.` });
        return;
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      const splitter = new LineSplitter();
      const push = (raw: string) => {
        const e = parseLine(raw);
        if (e) emit(e);
      };
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        watch();
        splitter.push(decoder.decode(value, { stream: true })).forEach(push);
      }
      splitter.flush().forEach(push);
    } catch (e) {
      // A stall ends quietly with a note, so the pipeline shows what the eyes found.
      if (stalled && !signal.aborted) {
        emit({ kind: 'error', text: 'The Lensi server stopped answering.' });
        return;
      }
      throw e;
    } finally {
      clearTimeout(timer);
      signal.removeEventListener('abort', stop);
    }
  },
};

import * as Speech from 'expo-speech';
import { useSyncExternalStore } from 'react';

let voice: string | null | undefined;

/** The nicest installed voice for the current language (Premium > Enhanced > default). */
async function pickVoice(): Promise<string | null> {
  if (voice !== undefined) return voice;
  try {
    const lang = (Intl.DateTimeFormat().resolvedOptions().locale || 'en-US').slice(0, 2);
    // A browser with no voices never answers (it waits for voices to arrive): don't wait on it.
    const all = await Promise.race([Speech.getAvailableVoicesAsync(), new Promise<null>((r) => setTimeout(() => r(null), 1200))]);
    const voices = (all ?? []).filter((v) => v.language?.startsWith(lang));
    const rank = (q: string | undefined) => (q === 'Premium' ? 2 : q === 'Enhanced' ? 1 : 0);
    voices.sort((a, b) => rank(b.quality as string) - rank(a.quality as string));
    voice = voices[0]?.identifier ?? null;
  } catch {
    voice = null;
  }
  return voice;
}

// Whether the app is talking, so an open mic can step aside rather than hear
// it. Each line gets a token: one that was cut off doesn't end the next.
let speaking = false;
let utterance = 0;
const listeners = new Set<() => void>();

function setSpeaking(on: boolean) {
  if (speaking === on) return;
  speaking = on;
  listeners.forEach((l) => l());
}

/** About how long a line takes to say: a backstop for a voice that never reports done. */
const sayMs = (text: string) => Math.min(20000, 1500 + text.length * 80);

/** Say something, cutting off whatever was being said. Resolves once it's said (or cut off). */
export async function say(text: string): Promise<void> {
  const token = ++utterance;
  setSpeaking(true);
  const v = await pickVoice();
  await Speech.stop().catch(() => {});
  if (token !== utterance) return;
  await new Promise<void>((resolve) => {
    let ended = false;
    const end = () => {
      if (ended) return;
      ended = true;
      clearTimeout(backstop);
      if (token === utterance) setSpeaking(false);
      resolve();
    };
    const backstop = setTimeout(end, sayMs(text));
    try {
      Speech.speak(text, { rate: 1.02, pitch: 1.0, ...(v ? { voice: v } : {}), onDone: end, onStopped: end, onError: end });
    } catch {
      end();
    }
  });
}

export function hush() {
  utterance++;
  setSpeaking(false);
  Speech.stop().catch(() => {});
}

/** True while the app is talking. */
export function useSpeaking(): boolean {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => speaking,
    () => speaking,
  );
}

import * as Speech from 'expo-speech';

let voice: string | null | undefined;

/** The nicest installed voice for the current language (Premium > Enhanced > default). */
async function pickVoice(): Promise<string | null> {
  if (voice !== undefined) return voice;
  try {
    const lang = (Intl.DateTimeFormat().resolvedOptions().locale || 'en-US').slice(0, 2);
    const voices = (await Speech.getAvailableVoicesAsync()).filter((v) => v.language?.startsWith(lang));
    const rank = (q: string | undefined) => (q === 'Premium' ? 2 : q === 'Enhanced' ? 1 : 0);
    voices.sort((a, b) => rank(b.quality as string) - rank(a.quality as string));
    voice = voices[0]?.identifier ?? null;
  } catch {
    voice = null;
  }
  return voice;
}

/** Say something, cutting off whatever was being said. */
export async function say(text: string) {
  const v = await pickVoice();
  await Speech.stop().catch(() => {});
  Speech.speak(text, { rate: 1.02, pitch: 1.0, ...(v ? { voice: v } : {}) });
}

export function hush() {
  Speech.stop().catch(() => {});
}

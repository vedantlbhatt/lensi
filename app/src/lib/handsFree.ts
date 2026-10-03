import { useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';

import { useSpeaking } from './narrate';
import type { useVoice } from './voice';

type Voice = ReturnType<typeof useVoice>;

/** Once the app stops talking, this long before the mic opens again (its own tail isn't heard). */
const REARM_MS = 450;

/**
 * Hands free: once someone has talked to the guide, the mic opens again each
 * time the app finishes talking, so "next", "check" or a question never needs
 * a greasy finger on the glass. It steps aside while the app speaks (so it
 * never hears itself) and ends with the job, a tap on the mic, or the app
 * going to the background.
 */
export function useHandsFree(voice: Voice, active: boolean) {
  const [on, setOn] = useState(false);
  const speaking = useSpeaking();
  const live = on && active;
  const liveRef = useRef(live);
  liveRef.current = live;
  const { listening, start, stop, isListening } = voice;

  useEffect(() => {
    if (!live) return;
    if (speaking) {
      if (isListening()) void stop();
      return;
    }
    if (listening) return;
    const t = setTimeout(() => {
      void start().then((ok) => {
        // No mic (permission, hardware): hands free can't work, so stop trying.
        if (ok === false) setOn(false);
        // The job ended (or it was switched off) while the mic was starting: close it again.
        else if (ok && !liveRef.current) void stop();
      });
    }, REARM_MS);
    return () => clearTimeout(t);
  }, [live, speaking, listening, start, stop, isListening]);

  // Switched off, or the guide went out of view: close the mic it opened.
  useEffect(() => {
    if (!live && isListening()) void stop();
    // Only on the switch itself; a tap-to-talk mic isn't ours to close.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [live]);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) => {
      if (s !== 'active') setOn(false);
    });
    return () => sub.remove();
  }, []);

  return { on: live, setOn };
}

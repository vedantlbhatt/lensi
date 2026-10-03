import { useCallback, useEffect, useRef, useState } from 'react';
import { useSharedValue, withTiming } from 'react-native-reanimated';

import { LensiAR } from '../../modules/lensi-ar/src';

/**
 * Push-to-talk on top of the native on-device recogniser. `level` is the mic
 * level (0…1) as a shared value so UI can breathe with the voice at 60 fps.
 */
export function useVoice() {
  const [listening, setListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  const [error, setError] = useState<string | null>(null);
  const latest = useRef('');
  const active = useRef(false);
  const level = useSharedValue(0);

  useEffect(() => {
    const sub = LensiAR.addListener('onSpeech', (e) => {
      // Several screens may hold this hook; only the one listening reacts.
      if (!active.current) return;
      if (e.error) {
        setError(e.error);
        return;
      }
      latest.current = e.transcript;
      setTranscript(e.transcript);
      level.value = withTiming(Math.max(0, Math.min(1, e.level)), { duration: 90 });
    });
    return () => sub.remove();
  }, [level]);

  const start = useCallback(async () => {
    setError(null);
    latest.current = '';
    setTranscript('');
    let ok = false;
    try {
      ok = await LensiAR.speechRequestPermission();
    } catch {
      ok = false;
    }
    if (!ok) {
      setError('Allow microphone and speech recognition in Settings to ask out loud.');
      return false;
    }
    active.current = true;
    setListening(true);
    try {
      await LensiAR.speechStart();
      return true;
    } catch (e) {
      active.current = false;
      setListening(false);
      setError(e instanceof Error ? e.message : 'Could not start listening.');
      return false;
    }
  }, []);

  const stop = useCallback(async (): Promise<string> => {
    try {
      await LensiAR.speechStop();
    } catch {}
    // The final result can trail the stop call by a beat.
    await new Promise((r) => setTimeout(r, 260));
    active.current = false;
    setListening(false);
    level.value = withTiming(0, { duration: 200 });
    return latest.current.trim();
  }, [level]);

  /** Live flag for gesture callbacks that may hold a stale render's state. */
  const isListening = useCallback(() => active.current, []);

  return { listening, transcript, error, level, start, stop, isListening };
}

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
  /** The caller still wants to listen (false once the finger lifts). */
  const wanted = useRef(false);
  /** A stop winding down: the next start waits for it, and nobody stops twice. */
  const stopping = useRef<Promise<string> | null>(null);
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

  /** true once listening; false if it can't (an error says why); null if let go before it began. */
  const start = useCallback(async (): Promise<boolean | null> => {
    wanted.current = true;
    if (stopping.current) await stopping.current;
    // Let go again while the last session was winding down.
    if (!wanted.current) return null;
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
    // A permission alert may have taken the whole gesture: if the finger is
    // already up, don't start listening to nobody.
    if (!wanted.current) return null;
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

  const stop = useCallback((): Promise<string> => {
    wanted.current = false;
    if (!active.current) return Promise.resolve('');
    if (stopping.current) return stopping.current;
    // The UI lets go at once; the last words can still arrive while the recogniser winds down.
    setListening(false);
    level.value = withTiming(0, { duration: 200 });
    const done = (async () => {
      try {
        await LensiAR.speechStop();
      } catch {}
      // The final result can trail the stop call by a beat.
      await new Promise((r) => setTimeout(r, 260));
      active.current = false;
      stopping.current = null;
      return latest.current.trim();
    })();
    stopping.current = done;
    return done;
  }, [level]);

  /** Live flag for gesture callbacks that may hold a stale render's state. */
  const isListening = useCallback(() => active.current && !stopping.current, []);

  return { listening, transcript, error, level, start, stop, isListening };
}

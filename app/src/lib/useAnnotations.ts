import * as Haptics from 'expo-haptics';
import { useCallback, useRef, useState, type RefObject } from 'react';

import type { LensiARViewRef, SelectEvent } from '../../modules/lensi-ar/src';
import { streamAnnotation, type Lens } from './annotate';
import type { Line } from './protocol';

export const PALETTE = ['#FF5A4E', '#2E9BFF', '#14B88A', '#8B6CFF', '#FF7FB6', '#0FB5C9'];

export type Exchange = { question: string; answer: string[]; pending: boolean };

export type Annotation = {
  id: string;
  color: string;
  lens: Lens;
  label: string | null;
  image: string;
  title: string | null;
  summary: string | null;
  points: string[];
  facts: string[];
  exchanges: Exchange[];
  status: 'streaming' | 'done' | 'error';
  error: string | null;
};

export function useAnnotations(view: RefObject<LensiARViewRef | null>) {
  const [items, setItems] = useState<Annotation[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const aborts = useRef(new Map<string, AbortController>());
  const calloutCount = useRef(new Map<string, number>());
  const colorIndex = useRef(0);

  const patch = useCallback((id: string, fn: (a: Annotation) => Annotation) => {
    setItems((all) => all.map((a) => (a.id === id ? fn(a) : a)));
  }, []);

  const applyLine = useCallback(
    (id: string, line: Line, exchange?: number) => {
      switch (line.kind) {
        case 'title':
          view.current?.setPin(id, line.text, null);
          Haptics.selectionAsync();
          return patch(id, (a) => ({ ...a, title: line.text }));
        case 'summary':
          return patch(id, (a) => ({ ...a, summary: line.text }));
        case 'fact':
          return patch(id, (a) => ({ ...a, facts: [...a.facts, line.text] }));
        case 'point': {
          const n = (calloutCount.current.get(id) ?? 0) + 1;
          calloutCount.current.set(id, n);
          view.current?.addCallout(id, `${id}:${n}`, line.x, line.y, line.label);
          return patch(id, (a) => ({ ...a, points: [...a.points, line.label] }));
        }
        case 'answer':
          if (exchange === undefined) return;
          return patch(id, (a) => ({
            ...a,
            exchanges: a.exchanges.map((x, i) => (i === exchange ? { ...x, answer: [...x.answer, line.text] } : x)),
          }));
        case 'error':
          return patch(id, (a) => ({ ...a, status: 'error', error: line.text }));
      }
    },
    [patch, view],
  );

  const run = useCallback(
    async (id: string, req: Parameters<typeof streamAnnotation>[0], exchange?: number) => {
      aborts.current.get(id)?.abort();
      const controller = new AbortController();
      aborts.current.set(id, controller);
      try {
        await streamAnnotation(req, (line) => applyLine(id, line, exchange), controller.signal);
        patch(id, (a) => ({
          ...a,
          status: a.status === 'error' ? 'error' : 'done',
          exchanges: a.exchanges.map((x, i) => (i === exchange ? { ...x, pending: false } : x)),
        }));
      } catch (e) {
        if (controller.signal.aborted) return;
        patch(id, (a) => ({ ...a, status: 'error', error: "Can't reach the Lensi server." }));
      } finally {
        if (aborts.current.get(id) === controller) aborts.current.delete(id);
      }
    },
    [applyLine, patch],
  );

  const onSelect = useCallback(
    (e: SelectEvent, lens: Lens) => {
      const color = PALETTE[colorIndex.current++ % PALETTE.length];
      view.current?.setPin(e.id, e.label ?? 'Looking', color);
      setItems((all) => [
        ...all,
        {
          id: e.id,
          color,
          lens,
          label: e.label,
          image: e.image,
          title: null,
          summary: null,
          points: [],
          facts: [],
          exchanges: [],
          status: 'streaming',
          error: null,
        },
      ]);
      setSelectedId(e.id);
      if (!e.image) {
        patch(e.id, (a) => ({ ...a, status: 'error', error: 'Camera frame was empty.' }));
        return;
      }
      run(e.id, { image: e.image, label: e.label, lens });
    },
    [patch, run, view],
  );

  const ask = useCallback(
    (id: string, question: string) => {
      const item = items.find((a) => a.id === id);
      if (!item) return;
      const exchange = item.exchanges.length;
      patch(id, (a) => ({ ...a, exchanges: [...a.exchanges, { question, answer: [], pending: true }] }));
      run(id, { image: item.image, label: item.title ?? item.label, lens: item.lens, question }, exchange);
    },
    [items, patch, run],
  );

  const remove = useCallback(
    (id: string) => {
      aborts.current.get(id)?.abort();
      view.current?.removePin(id);
      setItems((all) => all.filter((a) => a.id !== id));
      setSelectedId((s) => (s === id ? null : s));
    },
    [view],
  );

  const clear = useCallback(() => {
    aborts.current.forEach((c) => c.abort());
    aborts.current.clear();
    view.current?.clearPins();
    setItems([]);
    setSelectedId(null);
  }, [view]);

  const selected = items.find((a) => a.id === selectedId) ?? null;
  return { items, selected, setSelectedId, onSelect, ask, remove, clear };
}

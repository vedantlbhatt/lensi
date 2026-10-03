import { File, Paths } from 'expo-file-system';
import { useCallback, useRef, type RefObject } from 'react';

import { LensiAR, type SelectEvent } from '../../modules/lensi-ar/src';
import type { CameraHandle } from '../components/camera/CameraSurface';
import { toast } from '../components/ui/Toast';
import { lensInfo, type Lens } from '../theme/tokens';
import { pickEngine } from './engines';
import { imageSize } from './media';
import { anchorFor, buildRegions, type AnalysisLike } from './regions';
import { getSettings } from './settings';
import type { Region } from './types';

const MAX_PIN_CALLOUTS = 4;

/**
 * Live mode: tap something on the camera and it gets a pin that stays put in
 * 3D as you move. The native view freezes the pose and hands us a crop; we run
 * the same eyes + brain on it and feed titles and callouts back as pins.
 */
export function useLivePins(camera: RefObject<CameraHandle | null>, lens: Lens) {
  const titles = useRef(new Map<string, string>());

  const onSelect = useCallback(
    async (e: SelectEvent) => {
      const view = camera.current?.native;
      if (!view) return;
      const pen = lensInfo(lens).pen;
      titles.current.set(e.id, e.label ?? 'Looking');
      await view.setPin(e.id, e.label ?? 'Looking', pen).catch(() => {});
      if (!e.image) return;

      const file = new File(Paths.cache, `pin-${e.id}.jpg`);
      file.write(e.image, { encoding: 'base64' });
      const size = await imageSize(file.uri);

      let regions: Region[] = [];
      try {
        regions = buildRegions((await LensiAR.analyze(file.uri)) as AnalysisLike).regions;
      } catch {}

      const engine = await pickEngine(getSettings().brain);
      const controller = new AbortController();
      let n = 0;
      try {
        await engine.run(
          { imageUri: file.uri, width: size.width, height: size.height, lens, regions, hint: e.label },
          (ev) => {
            if (ev.kind === 'title') {
              titles.current.set(e.id, ev.text);
              void view.setPin(e.id, ev.text, null).catch(() => {});
            } else if (ev.kind === 'callout' && n < MAX_PIN_CALLOUTS) {
              const r = ev.mark ? regions.find((x) => x.mark === ev.mark) : undefined;
              const at = r ? anchorFor(r) : ev.at;
              if (!at) return;
              n += 1;
              void view.addCallout(e.id, `${e.id}:${n}`, at.x, at.y, ev.label).catch(() => {});
            }
          },
          controller.signal,
        );
      } catch {
        void view.setPin(e.id, e.label ?? "Couldn't tell", null).catch(() => {});
      }
    },
    [camera, lens],
  );

  const onPinTap = useCallback((id: string) => {
    const t = titles.current.get(id);
    if (t) toast(t);
  }, []);

  return { onSelect, onPinTap };
}

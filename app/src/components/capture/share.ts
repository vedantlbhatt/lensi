import { ClipOp, FillType, ImageFormat, PaintStyle, Skia, StrokeCap, StrokeJoin, type SkCanvas, type SkColor, type SkFont, type SkTypeface } from '@shopify/react-native-skia';
import { Asset } from 'expo-asset';
import { File, Paths } from 'expo-file-system';
import * as Sharing from 'expo-sharing';
import { Platform } from 'react-native';

import { leaderPath, outlinePath } from '../../lib/geometry';
import type { Capture } from '../../lib/types';
import { lensInfo } from '../../theme/tokens';
import { toast } from '../ui/Toast';
import { labelText, type PlacedCallout, type Stage } from './layout';

const FONT_FILES = {
  display: require('@expo-google-fonts/bricolage-grotesque/800ExtraBold/BricolageGrotesque_800ExtraBold.ttf'),
  text: require('@expo-google-fonts/funnel-sans/400Regular/FunnelSans_400Regular.ttf'),
  mono: require('@expo-google-fonts/fragment-mono/400Regular/FragmentMono_400Regular.ttf'),
};

let faces: Promise<Record<keyof typeof FONT_FILES, SkTypeface | null>> | null = null;

function loadFaces() {
  faces ??= (async () => {
    const out = {} as Record<keyof typeof FONT_FILES, SkTypeface | null>;
    for (const [k, mod] of Object.entries(FONT_FILES) as [keyof typeof FONT_FILES, number][]) {
      try {
        const a = Asset.fromModule(mod);
        await a.downloadAsync();
        const data = await Skia.Data.fromURI(a.localUri ?? a.uri);
        out[k] = Skia.Typeface.MakeFreeTypeFaceFromData(data);
      } catch {
        out[k] = null;
      }
    }
    return out;
  })();
  return faces;
}

function wrap(text: string, font: SkFont, width: number, maxLines: number): string[] {
  const words = text.split(/\s+/);
  const lines: string[] = [];
  let cur = '';
  for (const w of words) {
    const next = cur ? `${cur} ${w}` : w;
    if (font.measureText(next).width > width && cur) {
      lines.push(cur);
      cur = w;
      if (lines.length === maxLines) break;
    } else cur = next;
  }
  if (lines.length < maxLines && cur) lines.push(cur);
  if (lines.length === maxLines && words.join(' ') !== lines.join(' ')) lines[maxLines - 1] = `${lines[maxLines - 1].replace(/\W*$/, '')}…`;
  return lines;
}

/**
 * Renders the annotated print the way it looks on screen (photo, outline,
 * dots, leaders, labels) plus a title footer, as a JPEG, then opens the share
 * sheet. Everything is redrawn with Skia at 3x so it stays crisp.
 */
export async function shareCapture(c: Capture, placed: PlacedCallout[], stage: Stage) {
  if (Platform.OS === 'web') {
    toast('Sharing works in the iOS app');
    return;
  }
  try {
    const uri = await renderAnnotated(c, placed, stage);
    if (!(await Sharing.isAvailableAsync())) {
      toast('Saved, but sharing is unavailable here');
      return;
    }
    await Sharing.shareAsync(uri, { mimeType: 'image/jpeg', UTI: 'public.jpeg', dialogTitle: c.annotation.title ?? 'Lensi' });
  } catch (e) {
    console.warn('[lensi] share failed', e);
    toast("Couldn't render that one");
  }
}

export async function renderAnnotated(c: Capture, placed: PlacedCallout[], stage: Stage): Promise<string> {
  const S = 3;
  const pad = 22;
  const { frame } = stage;
  const W = Math.round((stage.labelBounds.w + stage.labelBounds.x * 2) * S);
  const footer = 150;
  const H = Math.round((frame.h + pad * 2 + footer) * S);
  const surface = Skia.Surface.MakeOffscreen(W, H) ?? Skia.Surface.Make(W, H);
  if (!surface) throw new Error('no surface');
  const canvas = surface.getCanvas();
  const f = await loadFaces();
  const pen = Skia.Color(lensInfo(c.lens).pen);
  const paperC = Skia.Color('#F4F1EA');
  const inkC = Skia.Color('#0B0B0C');

  // Screen → export space: keep x, shift y so the frame starts at `pad`.
  const X = (x: number) => x * S;
  const Y = (y: number) => (y - frame.y + pad) * S;

  canvas.drawColor(inkC);

  // Photo, clipped to the print's rounded rect.
  const data = await Skia.Data.fromURI(c.media.stillUri);
  const img = Skia.Image.MakeImageFromEncoded(data);
  const dest = Skia.XYWHRect(X(frame.x), Y(frame.y), frame.w * S, frame.h * S);
  const rr = Skia.RRectXY(dest, 26 * S, 26 * S);
  canvas.save();
  canvas.clipRRect(rr, ClipOp.Intersect, true);
  if (img) canvas.drawImageRect(img, Skia.XYWHRect(0, 0, img.width(), img.height()), dest, Skia.Paint());
  drawOverlay(canvas, c, { x: X(frame.x), y: Y(frame.y), w: frame.w * S, h: frame.h * S }, S, pen);
  canvas.restore();

  // Leaders, dots, labels.
  const stroke = (color: SkColor, w: number) => {
    const p = Skia.Paint();
    p.setStyle(PaintStyle.Stroke);
    p.setStrokeWidth(w);
    p.setStrokeCap(StrokeCap.Round);
    p.setStrokeJoin(StrokeJoin.Round);
    p.setColor(color);
    p.setAntiAlias(true);
    return p;
  };
  const fill = (color: SkColor) => {
    const p = Skia.Paint();
    p.setColor(color);
    p.setAntiAlias(true);
    return p;
  };
  const monoFont = Skia.Font(f.mono ?? undefined, 12 * S);
  for (const k of placed) {
    const d = leaderPath({ x: X(k.slot.anchor.x), y: Y(k.slot.anchor.y) }, { x: X(k.slot.attach.x), y: Y(k.slot.attach.y) });
    const path = Skia.Path.MakeFromSVGString(d);
    if (path) {
      canvas.drawPath(path, stroke(Skia.Color('rgba(0,0,0,0.3)'), 3.2 * S));
      canvas.drawPath(path, stroke(Skia.Color('rgba(255,255,255,0.95)'), 1.4 * S));
    }
    canvas.drawCircle(X(k.slot.anchor.x), Y(k.slot.anchor.y), 5.4 * S, fill(Skia.Color('#FFFFFF')));
    canvas.drawCircle(X(k.slot.anchor.x), Y(k.slot.anchor.y), 3.6 * S, fill(pen));
    const box = Skia.XYWHRect(X(k.slot.x), Y(k.slot.y), k.width * S, 28 * S);
    canvas.drawRRect(Skia.RRectXY(box, 9 * S, 9 * S), fill(Skia.Color('rgba(11,11,12,0.88)')));
    canvas.drawCircle(X(k.slot.x) + 13 * S, Y(k.slot.y) + 14 * S, 3 * S, fill(pen));
    canvas.drawText(labelText(k.label), X(k.slot.x) + 23 * S, Y(k.slot.y) + 18.2 * S, fill(paperC), monoFont);
  }

  // Footer: title, summary, wordmark.
  const top = Y(frame.y + frame.h) + 18 * S;
  const left = X(frame.x) + 2 * S;
  const width = frame.w * S - 4 * S;
  const titleFont = Skia.Font(f.display ?? undefined, 26 * S);
  const textFont = Skia.Font(f.text ?? undefined, 14 * S);
  const smallMono = Skia.Font(f.mono ?? undefined, 10 * S);
  canvas.drawText((c.annotation.title ?? 'Lensi').slice(0, 40), left, top + 26 * S, fill(paperC), titleFont);
  wrap(c.annotation.summary ?? '', textFont, width, 2).forEach((line, i) =>
    canvas.drawText(line, left, top + (52 + i * 19) * S, fill(Skia.Color('rgba(244,241,234,0.7)')), textFont),
  );
  const mark = `LENSI · ${lensInfo(c.lens).name.toUpperCase()}`;
  canvas.drawCircle(left + 4 * S, H - 26 * S, 3.5 * S, fill(pen));
  canvas.drawText(mark, left + 14 * S, H - 22.5 * S, fill(Skia.Color('rgba(244,241,234,0.55)')), smallMono);

  surface.flush();
  const out = surface.makeImageSnapshot().encodeToBase64(ImageFormat.JPEG, 92);
  const file = new File(Paths.cache, `lensi-${c.id}.jpg`);
  if (file.exists) file.delete();
  file.write(out, { encoding: 'base64' });
  return file.uri;
}

function drawOverlay(canvas: SkCanvas, c: Capture, dest: { x: number; y: number; w: number; h: number }, S: number, pen: SkColor) {
  const poly = c.subject?.polygon;
  if (!poly || poly.length < 3) return;
  const path = Skia.Path.MakeFromSVGString(outlinePath(poly, dest, 0.55));
  if (!path) return;
  const dim = path.copy();
  dim.addRect(Skia.XYWHRect(dest.x - 4, dest.y - 4, dest.w + 8, dest.h + 8));
  dim.setFillType(FillType.EvenOdd);
  const shade = Skia.Paint();
  shade.setColor(Skia.Color('rgba(0,0,0,0.3)'));
  shade.setAntiAlias(true);
  canvas.drawPath(dim, shade);
  const line = Skia.Paint();
  line.setStyle(PaintStyle.Stroke);
  line.setStrokeWidth(2.6 * S);
  line.setStrokeJoin(StrokeJoin.Round);
  line.setColor(pen);
  line.setAntiAlias(true);
  canvas.drawPath(path, line);
}

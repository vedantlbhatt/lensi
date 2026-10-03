import { Asset } from 'expo-asset';
import * as Clipboard from 'expo-clipboard';
import * as DocumentPicker from 'expo-document-picker';
import { File, Paths } from 'expo-file-system';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { createVideoPlayer } from 'expo-video';
import * as VideoThumbnails from 'expo-video-thumbnails';
import { Image, Platform } from 'react-native';

import type { MediaKind, Moment, Source } from './types';

/** Anything the user handed us, before it becomes a Capture. */
export type Picked = {
  kind: MediaKind;
  uri: string;
  width: number;
  height: number;
  durationMs?: number;
  source: Source;
};

export async function imageSize(uri: string): Promise<{ width: number; height: number }> {
  if (Platform.OS === 'web') {
    return new Promise((resolve) =>
      Image.getSize(uri, (width, height) => resolve({ width, height }), () => resolve({ width: 1000, height: 1000 })),
    );
  }
  try {
    const ref = await ImageManipulator.manipulate(uri).renderAsync();
    return { width: ref.width, height: ref.height };
  } catch {
    return new Promise((resolve) =>
      Image.getSize(uri, (width, height) => resolve({ width, height }), () => resolve({ width: 1000, height: 1000 })),
    );
  }
}

/**
 * Web preview only: the pickers hand back blob: and data: URIs with no name,
 * and the scripted stand-in engine knows its demo scenes by file name. A
 * fragment carries the name without changing what the URI loads.
 */
const named = (uri: string, name?: string | null) =>
  Platform.OS === 'web' && name && /^(blob|data):/.test(uri) && !uri.includes('#') ? `${uri}#${name}` : uri;

const isVideoName = (name: string, mime?: string | null) =>
  (mime ?? '').startsWith('video/') || /\.(mov|mp4|m4v|webm)$/i.test(name);

export async function pickFromLibrary(): Promise<Picked | null> {
  const res = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['images', 'videos'],
    quality: 1,
    allowsEditing: false,
    videoMaxDuration: 60,
  });
  if (res.canceled || !res.assets?.[0]) return null;
  const a = res.assets[0];
  const kind: MediaKind = a.type === 'video' ? 'video' : 'image';
  let { width, height } = a;
  if (!width || !height) ({ width, height } = await imageSize(a.uri));
  return { kind, uri: named(a.uri, a.fileName), width, height, durationMs: a.duration ?? undefined, source: 'library' };
}

/** One more photo for a capture: from the library, or the system camera. */
export async function pickPhoto(from: 'library' | 'camera'): Promise<Picked | null> {
  if (from === 'camera') {
    const perm = await ImagePicker.requestCameraPermissionsAsync();
    if (!perm.granted) return null;
  }
  const opts = { mediaTypes: ['images'] as ImagePicker.MediaType[], quality: 1, allowsEditing: false };
  const res = from === 'camera' ? await ImagePicker.launchCameraAsync(opts) : await ImagePicker.launchImageLibraryAsync(opts);
  if (res.canceled || !res.assets?.[0]) return null;
  const a = res.assets[0];
  let { width, height } = a;
  if (!width || !height) ({ width, height } = await imageSize(a.uri));
  return { kind: 'image', uri: named(a.uri, a.fileName), width, height, source: from === 'camera' ? 'camera' : 'library' };
}

export async function pickFromFiles(): Promise<Picked | null> {
  const res = await DocumentPicker.getDocumentAsync({ type: ['image/*', 'video/*'], copyToCacheDirectory: true });
  if (res.canceled || !res.assets?.[0]) return null;
  const a = res.assets[0];
  return pickedFromFile(a.uri, a.name, a.mimeType, 'files');
}

/** A photo or video file on the phone, as a capture's input. */
export async function pickedFromFile(file: string, name: string, mimeType: string | undefined, source: Picked['source']): Promise<Picked> {
  const uri = named(file, name);
  if (isVideoName(name, mimeType)) {
    const [frame, durationMs] = await Promise.all([
      VideoThumbnails.getThumbnailAsync(uri, { time: 0, quality: 0.9 }).catch(() => null),
      videoDurationMs(uri),
    ]);
    return { kind: 'video', uri, width: frame?.width ?? 1080, height: frame?.height ?? 1920, durationMs, source };
  }
  const size = await imageSize(uri);
  return { kind: 'image', uri, ...size, source };
}

/**
 * How long a video is. The pickers don't say for files, and without it every
 * keyframe would come from the first three seconds of the clip.
 */
export async function videoDurationMs(uri: string): Promise<number | undefined> {
  if (Platform.OS === 'web') return undefined;
  const player = createVideoPlayer(uri);
  try {
    return await new Promise<number | undefined>((resolve) => {
      const done = (seconds?: number) => {
        sub.remove();
        clearTimeout(timer);
        resolve(seconds && Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds * 1000) : undefined);
      };
      const sub = player.addListener('sourceLoad', (e) => done(e.duration));
      const timer = setTimeout(() => done(player.duration), 4000);
    });
  } finally {
    player.release();
  }
}

export async function pasteFromClipboard(): Promise<Picked | null> {
  if (!(await Clipboard.hasImageAsync())) return null;
  const img = await Clipboard.getImageAsync({ format: 'jpeg' });
  if (!img?.data) return null;
  const base64 = img.data.replace(/^data:image\/\w+;base64,/, '');
  if (Platform.OS === 'web') return { kind: 'image', uri: img.data, width: img.size.width, height: img.size.height, source: 'clipboard' };
  const file = new File(Paths.cache, `paste-${Date.now()}.jpg`);
  file.write(base64, { encoding: 'base64' });
  return { kind: 'image', uri: file.uri, width: img.size.width, height: img.size.height, source: 'clipboard' };
}

/** The Simulator / web "camera": a bundled demo photo resolved to a local file. */
export async function assetPhoto(module: number, width: number, height: number): Promise<Picked> {
  const asset = Asset.fromModule(module);
  await asset.downloadAsync();
  return { kind: 'image', uri: asset.localUri ?? asset.uri, width, height, source: 'camera' };
}

/** Three stills across the clip: start, middle, end. The middle one is analysed first. */
export async function videoMoments(uri: string, durationMs?: number): Promise<Moment[]> {
  const d = durationMs && durationMs > 0 ? durationMs : 3000;
  const times = [0.12, 0.5, 0.88].map((f) => Math.round(d * f));
  const out: Moment[] = [];
  for (const t of times) {
    try {
      const frame = await VideoThumbnails.getThumbnailAsync(uri, { time: t, quality: 0.85 });
      out.push({ t, uri: frame.uri });
    } catch {
      // Some containers refuse to seek near the end; skip that moment.
    }
  }
  return out;
}

/** Re-encodes very large stills so analysis and the model see a sane size. */
export async function normalizeStill(uri: string, width: number, height: number): Promise<{ uri: string; width: number; height: number }> {
  const longest = Math.max(width, height);
  if (Platform.OS === 'web' || longest <= 2400) return { uri, width, height };
  const scale = 2400 / longest;
  try {
    const ref = await ImageManipulator.manipulate(uri)
      .resize({ width: Math.round(width * scale), height: Math.round(height * scale) })
      .renderAsync();
    const out = await ref.saveAsync({ compress: 0.88, format: SaveFormat.JPEG });
    return { uri: out.uri, width: out.width, height: out.height };
  } catch {
    return { uri, width, height };
  }
}

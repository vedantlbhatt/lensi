/**
 * Black and white, like the Camera app, plus one highlighter per lens for
 * what the app draws on the world.
 */
export const ink = '#0B0B0C';
export const ink2 = '#151517';
export const paper = '#FFFFFF';
export const mist = 'rgba(255,255,255,0.66)';
export const faint = 'rgba(255,255,255,0.42)';
export const hairline = 'rgba(255,255,255,0.14)';
export const glass = 'rgba(14,14,16,0.56)';
export const glassStrong = 'rgba(14,14,16,0.82)';
export const record = '#FF3B30';

export type Lens = 'identify' | 'guide' | 'fix' | 'shop' | 'safe' | 'learn';

export type LensInfo = {
  key: Lens;
  name: string;
  /** What the lens asks the model for, in the user's words. */
  verb: string;
  pen: string;
  /** Ink that reads on top of `pen`. */
  onPen: string;
};

export const LENSES: LensInfo[] = [
  { key: 'guide', name: 'Guide', verb: 'Walk me through it', pen: '#FF9B3D', onPen: ink },
  { key: 'identify', name: 'Identify', verb: 'What is this?', pen: '#E4FF4F', onPen: ink },
  { key: 'fix', name: 'Fix', verb: "Why isn't it working?", pen: '#FF5D5D', onPen: ink },
  { key: 'shop', name: 'Shop', verb: 'Is it worth it?', pen: '#5CF2A6', onPen: ink },
  { key: 'safe', name: 'Safe', verb: 'Anything risky here?', pen: '#FF8BD1', onPen: ink },
  { key: 'learn', name: 'Learn', verb: 'How does it work?', pen: '#B8A6FF', onPen: ink },
];

export function lensInfo(lens: Lens): LensInfo {
  return LENSES.find((l) => l.key === lens) ?? LENSES[0];
}

/** Alpha helper for #RRGGBB strings (rounded, so it is safe in worklets too). */
export { rgba as alpha } from '../lib/color';

export const radius = { xs: 8, sm: 12, md: 18, lg: 26, xl: 34, pill: 999 } as const;
export const space = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const;

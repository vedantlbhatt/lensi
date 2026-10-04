import { NativeModule, requireNativeModule, requireNativeView } from 'expo';

import type { LensiAREvents, LensiARModuleShape, LensiARViewProps } from './types';

export * from './types';
export type { DemoScene, VideoThing, VideoTracks } from './demo';
export { DEMO_SCENES, sceneForUri } from './demo';

declare class LensiARNative extends NativeModule<LensiAREvents> implements LensiARModuleShape {
  isSupported: boolean;
  launchURL?: string | null;
  runtime?: string | null;
  analyze: LensiARModuleShape['analyze'];
  segment: LensiARModuleShape['segment'];
  intelligenceStatus: LensiARModuleShape['intelligenceStatus'];
  intelligencePrewarm: LensiARModuleShape['intelligencePrewarm'];
  intelligenceStart: LensiARModuleShape['intelligenceStart'];
  intelligenceCancel: LensiARModuleShape['intelligenceCancel'];
  speechRequestPermission: LensiARModuleShape['speechRequestPermission'];
  speechStart: LensiARModuleShape['speechStart'];
  speechStop: LensiARModuleShape['speechStop'];
  setKeepAwake: LensiARModuleShape['setKeepAwake'];
}

export const LensiAR = requireNativeModule<LensiARNative>('LensiAR');
export const isSupported: boolean = LensiAR.isSupported;
/** No ARKit (e.g. the Simulator): the app shows a virtual camera over the demo scenes. */
export const isVirtual = !LensiAR.isSupported;
export const LensiARView = requireNativeView<LensiARViewProps>('LensiAR');

/** Web preview hook; the real recogniser hears the real question. */
export function setDemoQuestion(_q: string) {}

/** Web preview hook (scripted hands-free turns); a no-op on a device. */
export function setDemoTalk(_lines: string[]) {}

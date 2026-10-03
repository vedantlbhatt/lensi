import { NativeModule, requireNativeModule, requireNativeView } from 'expo';

import type { LensiAREvents, LensiARModuleShape, LensiARViewProps } from './types';

export * from './types';
export type { DemoScene } from './demo';
export { DEMO_SCENES, sceneForUri } from './demo';

declare class LensiARNative extends NativeModule<LensiAREvents> implements LensiARModuleShape {
  isSupported: boolean;
  analyze: LensiARModuleShape['analyze'];
  segment: LensiARModuleShape['segment'];
  intelligenceStatus: LensiARModuleShape['intelligenceStatus'];
  intelligenceStart: LensiARModuleShape['intelligenceStart'];
  intelligenceCancel: LensiARModuleShape['intelligenceCancel'];
  speechRequestPermission: LensiARModuleShape['speechRequestPermission'];
  speechStart: LensiARModuleShape['speechStart'];
  speechStop: LensiARModuleShape['speechStop'];
}

export const LensiAR = requireNativeModule<LensiARNative>('LensiAR');
export const isSupported: boolean = LensiAR.isSupported;
/** No ARKit (e.g. the Simulator): the app shows a virtual camera over the demo scenes. */
export const isVirtual = !LensiAR.isSupported;
export const LensiARView = requireNativeView<LensiARViewProps>('LensiAR');

/** Web preview hook; the real recogniser hears the real question. */
export function setDemoQuestion(_q: string) {}

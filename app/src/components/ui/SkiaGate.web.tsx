import type { ReactNode } from 'react';

/** CanvasKit is loaded by index.web.js before the app is imported. */
export function SkiaGate({ children }: { children: ReactNode }) {
  return <>{children}</>;
}

import type { ReactNode } from 'react';

/** Native: Skia is linked in, nothing to wait for. (Web loads CanvasKit first.) */
export function SkiaGate({ children }: { children: ReactNode }) {
  return <>{children}</>;
}

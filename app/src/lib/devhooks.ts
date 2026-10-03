/**
 * Switches set by scripted runs (deep-link query params) so CI can exercise
 * paths that normally need a tap, e.g. rendering the share image.
 */
export const devhooks: { autoExport: boolean; autoTap: { x: number; y: number } | null; autoMoment: number | null } = {
  autoExport: false,
  autoTap: null,
  autoMoment: null,
};

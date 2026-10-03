import { File, Paths } from 'expo-file-system';
import { Platform } from 'react-native';

/**
 * Switches set by scripted runs (deep-link query params) so CI can exercise
 * paths that normally need a tap, e.g. rendering the share image.
 */
export const devhooks: {
  autoExport: boolean;
  autoTap: { x: number; y: number } | null;
  autoMoment: number | null;
  /** A scripted step failed: leave the error in Documents, where CI collects it (Release builds log no JS). */
  report: (what: string, e: unknown) => void;
} = {
  autoExport: false,
  autoTap: null,
  autoMoment: null,
  report(what, e) {
    if (Platform.OS === 'web') return;
    try {
      const err = e instanceof Error ? `${e.message}\n${e.stack ?? ''}` : String(e);
      new File(Paths.document, `lensi-${what}-error.txt`).write(err);
    } catch {
      // Nothing else to do: this is the error path's own error path.
    }
  },
};

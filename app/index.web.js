// Web preview only: Skia binds to CanvasKit when its modules are first
// evaluated, so the wasm must be loaded before the app is required. A plain
// inline require keeps everything in one bundle but defers evaluation.
import { LoadSkiaWeb } from '@shopify/react-native-skia/lib/module/web';

LoadSkiaWeb({ locateFile: (file) => `/${file}` }).then(() => {
  require('expo-router/entry');
});

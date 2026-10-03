import { Platform, type TextStyle } from 'react-native';

/**
 * One typeface: the iPhone's own, SF Pro. Asking for the family "System" with a
 * weight gets SF Pro Text or Display at the right optical size, the same as
 * every Apple app. The web preview has no SF, so it loads Inter, the nearest
 * open match, one family per weight.
 */
const web = Platform.OS === 'web';

function weight(w: '400' | '500' | '600' | '700' | '800', webFamily: string): TextStyle {
  return web ? { fontFamily: webFamily } : { fontFamily: 'System', fontWeight: w };
}

export const face = {
  regular: weight('400', 'Inter-Regular'),
  medium: weight('500', 'Inter-Medium'),
  semibold: weight('600', 'Inter-SemiBold'),
  bold: weight('700', 'Inter-Bold'),
  heavy: weight('800', 'Inter-ExtraBold'),
} satisfies Record<string, TextStyle>;

/** Loaded with useFonts on the web only; iOS needs nothing. */
export const fontAssets: Record<string, number> = web
  ? {
      'Inter-Regular': require('@expo-google-fonts/inter/400Regular/Inter_400Regular.ttf'),
      'Inter-Medium': require('@expo-google-fonts/inter/500Medium/Inter_500Medium.ttf'),
      'Inter-SemiBold': require('@expo-google-fonts/inter/600SemiBold/Inter_600SemiBold.ttf'),
      'Inter-Bold': require('@expo-google-fonts/inter/700Bold/Inter_700Bold.ttf'),
      'Inter-ExtraBold': require('@expo-google-fonts/inter/800ExtraBold/Inter_800ExtraBold.ttf'),
    }
  : {};

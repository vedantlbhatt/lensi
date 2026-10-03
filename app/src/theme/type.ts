import type { TextStyle } from 'react-native';

/**
 * Four faces, each with one job. Family names are the fonts' PostScript names,
 * so they resolve the same way when embedded by the expo-font config plugin
 * (iOS), loaded with useFonts (web), or looked up from Swift via UIFont(name:).
 *
 *   display  Bricolage Grotesque — titles, the wordmark, anything shouted
 *   text     Funnel Sans         — UI and reading text
 *   mono     Fragment Mono       — machine voice: labels the model reads off, counters
 *   serif    Instrument Serif    — the occasional editorial aside
 */
export const fonts = {
  display: 'BricolageGrotesque-ExtraBold',
  displayBold: 'BricolageGrotesque-Bold',
  text: 'FunnelSans-Regular',
  textMedium: 'FunnelSans-Medium',
  textSemi: 'FunnelSans-SemiBold',
  textBold: 'FunnelSans-Bold',
  mono: 'FragmentMono-Regular',
  serif: 'InstrumentSerif-Regular',
  serifItalic: 'InstrumentSerif-Italic',
} as const;

export const fontAssets = {
  'BricolageGrotesque-ExtraBold': require('@expo-google-fonts/bricolage-grotesque/800ExtraBold/BricolageGrotesque_800ExtraBold.ttf'),
  'BricolageGrotesque-Bold': require('@expo-google-fonts/bricolage-grotesque/700Bold/BricolageGrotesque_700Bold.ttf'),
  'FunnelSans-Regular': require('@expo-google-fonts/funnel-sans/400Regular/FunnelSans_400Regular.ttf'),
  'FunnelSans-Medium': require('@expo-google-fonts/funnel-sans/500Medium/FunnelSans_500Medium.ttf'),
  'FunnelSans-SemiBold': require('@expo-google-fonts/funnel-sans/600SemiBold/FunnelSans_600SemiBold.ttf'),
  'FunnelSans-Bold': require('@expo-google-fonts/funnel-sans/700Bold/FunnelSans_700Bold.ttf'),
  'FragmentMono-Regular': require('@expo-google-fonts/fragment-mono/400Regular/FragmentMono_400Regular.ttf'),
  'InstrumentSerif-Regular': require('@expo-google-fonts/instrument-serif/400Regular/InstrumentSerif_400Regular.ttf'),
  'InstrumentSerif-Italic': require('@expo-google-fonts/instrument-serif/400Regular_Italic/InstrumentSerif_400Regular_Italic.ttf'),
};

/** Text presets. Sizes follow a 1.25 scale anchored at 15. */
export const type = {
  hero: { fontFamily: fonts.display, fontSize: 44, lineHeight: 44, letterSpacing: -1.6 },
  title: { fontFamily: fonts.display, fontSize: 30, lineHeight: 32, letterSpacing: -0.9 },
  heading: { fontFamily: fonts.displayBold, fontSize: 21, lineHeight: 24, letterSpacing: -0.4 },
  body: { fontFamily: fonts.text, fontSize: 16, lineHeight: 22, letterSpacing: -0.1 },
  bodyStrong: { fontFamily: fonts.textSemi, fontSize: 16, lineHeight: 22, letterSpacing: -0.1 },
  ui: { fontFamily: fonts.textSemi, fontSize: 15, lineHeight: 18, letterSpacing: -0.1 },
  small: { fontFamily: fonts.textMedium, fontSize: 13, lineHeight: 16, letterSpacing: 0 },
  label: { fontFamily: fonts.mono, fontSize: 12, lineHeight: 14, letterSpacing: 0.2 },
  tag: { fontFamily: fonts.mono, fontSize: 11, lineHeight: 13, letterSpacing: 0.9, textTransform: 'uppercase' },
  aside: { fontFamily: fonts.serifItalic, fontSize: 22, lineHeight: 24, letterSpacing: -0.2 },
} satisfies Record<string, TextStyle>;

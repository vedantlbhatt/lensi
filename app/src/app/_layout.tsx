import { useFonts } from 'expo-font';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { StyleSheet } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';

import { SkiaGate } from '../components/ui/SkiaGate';
import { loadCaptures } from '../lib/store';
import { ink } from '../theme/tokens';
import { fontAssets } from '../theme/type';

SplashScreen.preventAutoHideAsync().catch(() => {});

export default function RootLayout() {
  // iOS uses the system font and loads nothing; the web preview loads Inter.
  const [fontsLoaded, fontError] = useFonts(fontAssets);

  useEffect(() => {
    loadCaptures();
  }, []);

  useEffect(() => {
    if (fontsLoaded || fontError) SplashScreen.hideAsync().catch(() => {});
  }, [fontsLoaded, fontError]);

  if (!fontsLoaded && !fontError) return null;

  return (
    <GestureHandlerRootView style={styles.root}>
      <SkiaGate>
        <StatusBar style="light" />
        <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: ink }, animation: 'fade' }} />
      </SkiaGate>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create({ root: { flex: 1, backgroundColor: ink } });

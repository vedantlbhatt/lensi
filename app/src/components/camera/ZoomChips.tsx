import { Pressable, StyleSheet, Text, View } from 'react-native';

import { face } from '../../theme/type';

const STOPS = [0.5, 1, 2, 5];

/** 0.5, 1, 2.4: the way the Camera app writes zoom. */
export function zoomText(z: number): string {
  if (z < 1) return `.${Math.round(z * 10)}`;
  const r = Math.round(z * 10) / 10;
  return Number.isInteger(r) ? `${r}` : r.toFixed(1);
}

/**
 * The Camera app's zoom stops. The stop the zoom is at (or just past) shows the
 * live value while pinching; tapping a stop jumps there. 0.5 only appears when
 * the camera has an ultra-wide it can track with.
 */
export function ZoomChips({
  zoom,
  min,
  max,
  pen,
  onZoom,
}: {
  zoom: number;
  min: number;
  max: number;
  pen: string;
  onZoom: (z: number) => void;
}) {
  const stops = STOPS.filter((s) => s >= min - 0.01 && s <= max + 0.01);
  const active = stops.reduce((a, s) => (zoom >= s - 0.05 ? s : a), stops[0]);
  return (
    <View style={styles.row} pointerEvents="box-none">
      {stops.map((s) => {
        const on = s === active;
        return (
          <Pressable
            key={s}
            onPress={() => onZoom(s)}
            hitSlop={6}
            accessibilityRole="button"
            accessibilityLabel={`Zoom ${zoomText(s)}x`}
            accessibilityState={{ selected: on }}
            style={[styles.chip, on && styles.on]}
          >
            <Text style={[styles.text, on && { color: pen }]}>{on ? `${zoomText(zoom)}×` : zoomText(s)}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    padding: 4,
    borderRadius: 22,
    backgroundColor: 'rgba(0,0,0,0.32)',
  },
  chip: { minWidth: 34, height: 34, borderRadius: 17, paddingHorizontal: 6, alignItems: 'center', justifyContent: 'center' },
  on: { minWidth: 42, backgroundColor: 'rgba(0,0,0,0.5)' },
  text: { color: '#FFFFFF', ...face.semibold, fontSize: 12, fontVariant: ['tabular-nums'] },
});

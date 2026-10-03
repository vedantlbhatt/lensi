import Svg, { Circle, Path, Rect } from 'react-native-svg';

/**
 * Lensi's own glyphs: 24-unit grid, 1.9 stroke, round ends, slightly soft
 * corners. Drawn here rather than pulled from an icon font so every one shares
 * the same hand.
 */
export type IconName =
  | 'close'
  | 'flash'
  | 'flashOff'
  | 'live'
  | 'drop'
  | 'sliders'
  | 'share'
  | 'mic'
  | 'send'
  | 'left'
  | 'right'
  | 'stack'
  | 'trash'
  | 'voice'
  | 'voiceOff'
  | 'spark'
  | 'photo'
  | 'file'
  | 'paste'
  | 'retry'
  | 'play'
  | 'pause'
  | 'check'
  | 'down'
  | 'cloud'
  | 'eye'
  | 'chip'
  | 'download'
  | 'pencil';

export function Icon({
  name,
  size = 24,
  color = '#F4F1EA',
  stroke = 1.9,
  fill,
}: {
  name: IconName;
  size?: number;
  color?: string;
  stroke?: number;
  fill?: string;
}) {
  const p = { stroke: color, strokeWidth: stroke, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const, fill: 'none' };
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      {glyph(name, p, color, fill)}
    </Svg>
  );
}

type P = { stroke: string; strokeWidth: number; strokeLinecap: 'round'; strokeLinejoin: 'round'; fill: string };

function glyph(name: IconName, p: P, color: string, fill?: string) {
  switch (name) {
    case 'close':
      return <Path {...p} d="M6.5 6.5l11 11M17.5 6.5l-11 11" />;
    case 'flash':
      return <Path {...p} fill={fill ?? 'none'} d="M13.2 3.2L5.8 13.1h5.6l-1.1 7.7 7.9-10.4h-5.8l.8-7.2z" />;
    case 'flashOff':
      return (
        <>
          <Path {...p} d="M13.2 3.2L9.6 8M8 10.2l-2.2 2.9h5.6l-1.1 7.7 4.3-5.7M15.6 12.7l2.1-2.3h-3.4" />
          <Path {...p} d="M4 4l16 16" />
        </>
      );
    case 'live':
      return (
        <>
          <Path {...p} d="M12 3.4l7.4 4.2v8.8L12 20.6l-7.4-4.2V7.6L12 3.4z" />
          <Path {...p} d="M4.8 7.7L12 11.9l7.2-4.2M12 11.9v8.5" />
        </>
      );
    case 'drop':
      return (
        <>
          <Path {...p} d="M12 3.5v10.2M8 9.8l4 4 4-4" />
          <Path {...p} d="M4.5 13.5v3.2a3 3 0 003 3h9a3 3 0 003-3v-3.2" />
        </>
      );
    case 'sliders':
      return (
        <>
          <Path {...p} d="M4 7.5h9.5M17.5 7.5H20M4 16.5h2.5M10.5 16.5H20" />
          <Circle {...p} cx={15.5} cy={7.5} r={2.1} />
          <Circle {...p} cx={8.5} cy={16.5} r={2.1} />
        </>
      );
    case 'share':
      return (
        <>
          <Path {...p} d="M12 14.5V3.8M8.2 7.4L12 3.6l3.8 3.8" />
          <Path {...p} d="M8 10.5H7a2.5 2.5 0 00-2.5 2.5v5A2.5 2.5 0 007 20.5h10a2.5 2.5 0 002.5-2.5v-5a2.5 2.5 0 00-2.5-2.5h-1" />
        </>
      );
    case 'mic':
      return (
        <>
          <Rect {...p} x={8.8} y={3.2} width={6.4} height={11.2} rx={3.2} fill={fill ?? 'none'} />
          <Path {...p} d="M5.6 11.3a6.4 6.4 0 0012.8 0M12 17.8v3" />
        </>
      );
    case 'send':
      return <Path {...p} d="M12 19.5V5M6 10.8L12 4.8l6 6" />;
    case 'left':
      return <Path {...p} d="M14.8 5.5L8.3 12l6.5 6.5" />;
    case 'right':
      return <Path {...p} d="M9.2 5.5l6.5 6.5-6.5 6.5" />;
    case 'down':
      return <Path {...p} d="M5.5 9.2l6.5 6.5 6.5-6.5" />;
    case 'stack':
      return (
        <>
          <Rect {...p} x={4.2} y={7.8} width={15.6} height={12.4} rx={3} />
          <Path {...p} d="M6.6 5.2h10.8M9 2.8h6" />
        </>
      );
    case 'trash':
      return (
        <>
          <Path {...p} d="M4.5 6.8h15M9.5 6.6V4.8c0-.7.6-1.3 1.3-1.3h2.4c.7 0 1.3.6 1.3 1.3v1.8" />
          <Path {...p} d="M6.5 6.8l.9 11.6a2 2 0 002 1.8h5.2a2 2 0 002-1.8l.9-11.6M10.2 10.6v5.6M13.8 10.6v5.6" />
        </>
      );
    case 'voice':
      return (
        <>
          <Path {...p} d="M4.5 9.6v4.8h3.2l4.6 3.8V5.8L7.7 9.6H4.5z" />
          <Path {...p} d="M15.8 9a4.2 4.2 0 010 6M18.5 6.6a7.6 7.6 0 010 10.8" />
        </>
      );
    case 'voiceOff':
      return (
        <>
          <Path {...p} d="M4.5 9.6v4.8h3.2l4.6 3.8V5.8L7.7 9.6H4.5z" />
          <Path {...p} d="M16 9.5l5 5M21 9.5l-5 5" />
        </>
      );
    case 'spark':
      return (
        <Path
          {...p}
          fill={fill ?? 'none'}
          d="M12 3.2c.5 4.3 2.4 6.3 6.8 6.8-4.4.5-6.3 2.5-6.8 6.8-.5-4.3-2.4-6.3-6.8-6.8 4.4-.5 6.3-2.5 6.8-6.8zM18.4 15.4c.2 1.7 1 2.5 2.6 2.7-1.6.2-2.4 1-2.6 2.7-.2-1.7-1-2.5-2.6-2.7 1.6-.2 2.4-1 2.6-2.7z"
        />
      );
    case 'photo':
      return (
        <>
          <Rect {...p} x={3.5} y={4.5} width={17} height={15} rx={3.2} />
          <Path {...p} d="M3.8 16.2l4.6-4.4a1.6 1.6 0 012.2 0l5.4 5.4M14 14.5l1.6-1.5a1.6 1.6 0 012.2 0l2.4 2.3" />
          <Circle cx={15.6} cy={9} r={1.6} fill={color} />
        </>
      );
    case 'file':
      return (
        <>
          <Path {...p} d="M13.5 3.5H7.8a2.3 2.3 0 00-2.3 2.3v12.4a2.3 2.3 0 002.3 2.3h8.4a2.3 2.3 0 002.3-2.3V8.5l-5-5z" />
          <Path {...p} d="M13.3 3.7v4.8h4.9M9 13h6M9 16.4h4" />
        </>
      );
    case 'paste':
      return (
        <>
          <Path {...p} d="M9 5H7.3A2.3 2.3 0 005 7.3v11.4A2.3 2.3 0 007.3 21h9.4a2.3 2.3 0 002.3-2.3V7.3A2.3 2.3 0 0016.7 5H15" />
          <Rect {...p} x={9} y={3} width={6} height={4} rx={1.6} />
        </>
      );
    case 'retry':
      return (
        <>
          <Path {...p} d="M19.2 12a7.2 7.2 0 11-2.1-5.1" />
          <Path {...p} d="M19.4 4.6v3.6h-3.6" />
        </>
      );
    case 'play':
      return <Path {...p} fill={fill ?? color} d="M8 5.6v12.8a.9.9 0 001.4.8l10-6.4a.9.9 0 000-1.6l-10-6.4a.9.9 0 00-1.4.8z" />;
    case 'pause':
      return (
        <>
          <Rect x={6.6} y={5} width={3.6} height={14} rx={1.3} fill={color} />
          <Rect x={13.8} y={5} width={3.6} height={14} rx={1.3} fill={color} />
        </>
      );
    case 'check':
      return <Path {...p} d="M5.2 12.6l4.3 4.3 9.3-9.6" />;
    case 'pencil':
      return (
        <>
          <Path {...p} d="M14.6 5.6l3.8 3.8M5 19l.9-4.1L15.7 5.1a1.9 1.9 0 012.7 0l.5.5a1.9 1.9 0 010 2.7L9.1 18.1 5 19z" />
        </>
      );
    case 'cloud':
      return <Path {...p} d="M7.4 18.5a4.4 4.4 0 01-.7-8.7 5.6 5.6 0 0110.9 1.3 3.7 3.7 0 01-.6 7.4H7.4z" />;
    case 'eye':
      return (
        <>
          <Path {...p} d="M2.8 12s3.4-6.3 9.2-6.3S21.2 12 21.2 12s-3.4 6.3-9.2 6.3S2.8 12 2.8 12z" />
          <Circle {...p} cx={12} cy={12} r={2.7} />
        </>
      );
    case 'chip':
      return (
        <>
          <Rect {...p} x={6.5} y={6.5} width={11} height={11} rx={2.4} />
          <Path {...p} d="M9.6 3.5v3M14.4 3.5v3M9.6 17.5v3M14.4 17.5v3M3.5 9.6h3M3.5 14.4h3M17.5 9.6h3M17.5 14.4h3" />
        </>
      );
    case 'download':
      return (
        <>
          <Path {...p} d="M12 4v11M7.6 10.8L12 15.2l4.4-4.4" />
          <Path {...p} d="M5 19.5h14" />
        </>
      );
  }
}

// Demo scenes for the web preview and the iOS Simulator's virtual camera.
// Images are public samples (segment-anything / sam2 notebooks, Apache-2.0;
// OpenCV samples, Apache-2.0), cropped to a portrait camera frame. Outlines
// were traced with GrabCut; the scripts stand in for a model on the web only.

type P = [number, number];
type Outline = { size: [number, number]; box: [number, number, number, number]; polygon: P[] };

const OUTLINES: Record<string, Outline> = {
  cars: { size: [900, 1200], box: [0.1689, 0.1933, 0.8311, 0.6017], polygon: [[0.9711, 0.1933], [0.5933, 0.2167], [0.4578, 0.2567], [0.4356, 0.2967], [0.2911, 0.295], [0.1689, 0.325], [0.2156, 0.4467], [0.1689, 0.5033], [0.2089, 0.5183], [0.2267, 0.7283], [0.2667, 0.76], [0.2422, 0.7883], [0.6489, 0.775], [0.8622, 0.7933], [0.8933, 0.72], [0.9978, 0.6967], [0.9822, 0.68], [0.6756, 0.6717], [0.6489, 0.6083], [0.5356, 0.6267], [0.4689, 0.585], [0.2378, 0.6017], [0.2378, 0.565], [0.3044, 0.5383], [0.9978, 0.525], [0.9978, 0.2633], [0.9756, 0.2567], [0.9978, 0.225]] },
  truck: { size: [900, 1200], box: [0.0, 0.235, 0.9689, 0.3817], polygon: [[0.0, 0.235], [0.0, 0.6], [0.4289, 0.595], [0.44, 0.5683], [0.5689, 0.5633], [0.6067, 0.55], [0.6867, 0.5517], [0.7, 0.5883], [0.74, 0.6117], [0.8222, 0.6033], [0.8511, 0.615], [0.8733, 0.555], [0.9422, 0.5367], [0.9644, 0.5167], [0.9533, 0.4317], [0.9111, 0.425], [0.8556, 0.3683], [0.54, 0.3467], [0.2956, 0.245]] },
  board: { size: [720, 960], box: [0.2756, 0.6483, 0.3933, 0.2533], polygon: [[0.3356, 0.6483], [0.3289, 0.6767], [0.3022, 0.6817], [0.2911, 0.6933], [0.2911, 0.73], [0.2778, 0.7317], [0.2756, 0.8233], [0.2911, 0.8267], [0.2911, 0.855], [0.3111, 0.8717], [0.3111, 0.8917], [0.5467, 0.9], [0.6467, 0.895], [0.6467, 0.875], [0.6667, 0.86], [0.6667, 0.6933], [0.6467, 0.68], [0.6467, 0.6517]] },
  groceries: { size: [600, 800], box: [0.3356, 0.27, 0.6533, 0.37], polygon: [[0.9511, 0.2717], [0.82, 0.2733], [0.8111, 0.3317], [0.7556, 0.3533], [0.7022, 0.355], [0.6644, 0.3383], [0.5422, 0.335], [0.5267, 0.3783], [0.3489, 0.3733], [0.3533, 0.4533], [0.3356, 0.5783], [0.3511, 0.6317], [0.4667, 0.6383], [0.4956, 0.6083], [0.5156, 0.6083], [0.5511, 0.6367], [0.6756, 0.6283], [0.6822, 0.6], [0.7822, 0.6333], [0.9178, 0.6283], [0.9711, 0.59], [0.9867, 0.365]] },
  fruits: { size: [720, 960], box: [0.0, 0.07, 0.7311, 0.9], polygon: [[0.0, 0.07], [0.0, 0.6683], [0.0467, 0.715], [0.0689, 0.8383], [0.18, 0.9167], [0.2778, 0.9583], [0.5533, 0.965], [0.6133, 0.9167], [0.6822, 0.8917], [0.66, 0.8083], [0.7289, 0.6833], [0.6244, 0.4333], [0.6311, 0.39], [0.5756, 0.3333], [0.5111, 0.1333], [0.4756, 0.0883], [0.32, 0.11], [0.2956, 0.1433], [0.2, 0.185], [0.1267, 0.1567], [0.0467, 0.07]] },
};

export type DemoScene = {
  key: string;
  /** Short caption shown on the virtual camera. */
  caption: string;
  asset: number;
  width: number;
  height: number;
  outline: Outline;
  text: { text: string; box: [number, number, number, number] }[];
  objects: { label: string; box: [number, number, number, number] }[];
  labels: string[];
  script: {
    title: string;
    summary: string;
    callouts: { label: string; at: P }[];
    facts: string[];
    steps: { text: string; at?: P }[];
    question: string;
  };
};

export const DEMO_SCENES: DemoScene[] = [
  {
    key: 'cars',
    caption: 'Havana, a pink classic',
    asset: require('../../../assets/demo/cars.jpg'),
    width: 900,
    height: 1200,
    outline: OUTLINES.cars,
    text: [{ text: 'CUBA', box: [0.86, 0.735, 0.13, 0.05] }],
    objects: [{ label: 'car', box: [0.17, 0.19, 0.83, 0.62] }],
    labels: ['car', 'vintage', 'chrome'],
    script: {
      title: "1950s Ford Fairlane",
      summary: 'A Havana street classic: hooded lamps, a full-width chrome grille and a Cuban plate.',
      callouts: [
        { label: 'Hooded headlamp', at: [0.3, 0.33] },
        { label: 'Wraparound windshield', at: [0.62, 0.2] },
        { label: 'Egg-crate grille', at: [0.62, 0.53] },
        { label: 'Bumper guard', at: [0.48, 0.68] },
        { label: 'Cuban plate', at: [0.93, 0.76] },
      ],
      facts: [
        'Cuba kept its 1950s American cars running for decades after the 1960 embargo.',
        'Many now hide modern diesel engines under the original hoods.',
        'Two-tone and pastel paint were popular factory options in 1956.',
      ],
      steps: [
        { text: 'Pull the hood release under the dash, left of the steering column.', at: [0.28, 0.3] },
        { text: 'Walk to the grille; the hood is now popped a few centimetres.', at: [0.62, 0.5] },
        { text: 'Slide your fingers under the hood centre and push the safety latch.', at: [0.6, 0.42] },
        { text: 'Lift the hood and set the prop rod before you let go.', at: [0.7, 0.3] },
      ],
      question: 'How do I open the hood?',
    },
  },
  {
    key: 'truck',
    caption: 'A white pickup, curbside',
    asset: require('../../../assets/demo/truck.jpg'),
    width: 900,
    height: 1200,
    outline: OUTLINES.truck,
    text: [],
    objects: [{ label: 'truck', box: [0.0, 0.235, 0.97, 0.38] }],
    labels: ['truck', 'pickup', 'wheel'],
    script: {
      title: 'Isuzu D-Max pickup',
      summary: 'Mid-size diesel pickup; the front tyre and door jamb are where a pressure check starts.',
      callouts: [
        { label: 'Side mirror', at: [0.47, 0.37] },
        { label: 'Door handle', at: [0.33, 0.43] },
        { label: 'Front tyre', at: [0.79, 0.54] },
        { label: 'Headlamp', at: [0.94, 0.41] },
      ],
      facts: [
        'Recommended pressures live on a sticker inside the driver door jamb.',
        'Check tyres cold: driving even a few kilometres raises the reading.',
        'Under-inflation by 20% can cost around 10% of tread life.',
      ],
      steps: [
        { text: 'Open the driver door and read the pressure sticker on the jamb.', at: [0.33, 0.43] },
        { text: 'Unscrew the valve cap on the front tyre.', at: [0.79, 0.52] },
        { text: 'Press the gauge straight onto the valve until the hiss stops.', at: [0.8, 0.55] },
        { text: 'Compare with the sticker and add air in short bursts.', at: [0.79, 0.54] },
      ],
      question: 'How do I check the tyre pressure?',
    },
  },
  {
    key: 'board',
    caption: 'An old sound card',
    asset: require('../../../assets/demo/board.jpg'),
    width: 720,
    height: 960,
    outline: OUTLINES.board,
    text: [
      { text: 'CREATIVE', box: [0.4, 0.735, 0.17, 0.035] },
      { text: '24.576', box: [0.4, 0.375, 0.12, 0.03] },
    ],
    objects: [],
    labels: ['circuit board', 'electronics', 'chip'],
    script: {
      title: 'Creative sound card',
      summary: 'The big square chip is the audio processor; the silver can beside it keeps time.',
      callouts: [
        { label: 'Audio DSP (Creative)', at: [0.47, 0.76] },
        { label: '24.576 MHz crystal', at: [0.46, 0.39] },
        { label: 'Filter capacitors', at: [0.55, 0.24] },
        { label: 'Jumper headers', at: [0.38, 0.06] },
        { label: 'Codec chip', at: [0.24, 0.31] },
      ],
      facts: [
        '24.576 MHz divides exactly into 48 kHz audio (×512), so no resampling is needed.',
        'The capacitors smooth the power rails: noisy power becomes audible hiss.',
        'QFP chips like this one are soldered on all four sides by reflow ovens.',
      ],
      steps: [
        { text: 'Find the crystal: every timing signal on the card starts here.', at: [0.46, 0.39] },
        { text: 'Follow it to the DSP, which mixes and processes the audio.', at: [0.47, 0.76] },
        { text: 'The codec turns the digital stream into analog voltage.', at: [0.24, 0.31] },
        { text: 'Capacitors keep that analog side quiet before it reaches the jack.', at: [0.55, 0.24] },
      ],
      question: 'How does the audio get from the chip to my speakers?',
    },
  },
  {
    key: 'groceries',
    caption: 'Groceries in the trunk',
    asset: require('../../../assets/demo/groceries.jpg'),
    width: 600,
    height: 800,
    outline: OUTLINES.groceries,
    text: [],
    objects: [{ label: 'handbag', box: [0.34, 0.33, 0.21, 0.31] }],
    labels: ['bag', 'groceries', 'car interior'],
    script: {
      title: 'Paper grocery bags',
      summary: 'Four full bags, upright against the seat back, nothing strapped down.',
      callouts: [
        { label: 'Leafy greens', at: [0.72, 0.3] },
        { label: 'Bottle on top', at: [0.84, 0.25] },
        { label: 'Heaviest bag', at: [0.42, 0.5] },
        { label: 'Open cargo floor', at: [0.55, 0.72] },
      ],
      facts: [
        'Loose bags slide forward under braking; wedge them against the seat back.',
        'Keep greens away from the hatch glass on hot days.',
        'Paper bags tear when wet: put chilled items in their own bag.',
      ],
      steps: [
        { text: 'Move the heaviest bag to the corner against the seat back.', at: [0.42, 0.5] },
        { text: 'Lay the bottle on its side so it cannot fall out when the hatch opens.', at: [0.84, 0.25] },
        { text: 'Put the greens on top, away from the glass.', at: [0.72, 0.3] },
      ],
      question: 'How should I pack this so nothing tips over?',
    },
  },
  {
    key: 'fruits',
    caption: 'Citrus, cut open',
    asset: require('../../../assets/demo/fruits.jpg'),
    width: 720,
    height: 960,
    outline: OUTLINES.fruits,
    text: [],
    objects: [{ label: 'orange', box: [0.0, 0.07, 0.73, 0.9] }],
    labels: ['orange', 'citrus', 'fruit'],
    script: {
      title: 'Navel orange, halved',
      summary: 'Ripe and juicy; the white pith is where most of the fibre is.',
      callouts: [
        { label: 'Juice vesicles', at: [0.4, 0.55] },
        { label: 'Pith (albedo)', at: [0.36, 0.33] },
        { label: 'Zest (flavedo)', at: [0.14, 0.4] },
        { label: 'Lime', at: [0.92, 0.38] },
      ],
      facts: [
        'One orange covers roughly a day of vitamin C for most adults.',
        'Grapefruit, not orange, is the citrus that interacts with many medicines.',
        'The zest holds the aromatic oils; the pith is bitter but fibrous.',
      ],
      steps: [
        { text: 'Score the peel from top to bottom in four places.', at: [0.14, 0.4] },
        { text: 'Peel back each quarter; the pith comes away with it.', at: [0.36, 0.33] },
        { text: 'Separate the segments along the white membranes.', at: [0.4, 0.55] },
      ],
      question: 'What is the cleanest way to peel this?',
    },
  },
];

export function sceneForUri(uri: string): DemoScene | null {
  const u = uri.toLowerCase();
  return DEMO_SCENES.find((s) => u.includes(`/${s.key}`) || u.includes(`${s.key}.`)) ?? null;
}

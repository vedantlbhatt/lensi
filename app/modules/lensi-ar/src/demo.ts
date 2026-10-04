// Demo scenes for the web preview and the iOS Simulator's virtual camera.
// Images are public samples (segment-anything / sam2 notebooks, Apache-2.0;
// OpenCV samples, Apache-2.0), cropped to a portrait camera frame. Outlines
// were traced with GrabCut; the scripts stand in for a model on the web only.

import { DEMO_VIDEO } from './demoVideos';

type P = [number, number];
type Outline = { size: [number, number]; box: [number, number, number, number]; polygon: P[] };

const OUTLINES: Record<string, Outline> = {
  cars: { size: [900, 1200], box: [0.1689, 0.1933, 0.8311, 0.6017], polygon: [[0.9711, 0.1933], [0.5933, 0.2167], [0.4578, 0.2567], [0.4356, 0.2967], [0.2911, 0.295], [0.1689, 0.325], [0.2156, 0.4467], [0.1689, 0.5033], [0.2089, 0.5183], [0.2267, 0.7283], [0.2667, 0.76], [0.2422, 0.7883], [0.6489, 0.775], [0.8622, 0.7933], [0.8933, 0.72], [0.9978, 0.6967], [0.9822, 0.68], [0.6756, 0.6717], [0.6489, 0.6083], [0.5356, 0.6267], [0.4689, 0.585], [0.2378, 0.6017], [0.2378, 0.565], [0.3044, 0.5383], [0.9978, 0.525], [0.9978, 0.2633], [0.9756, 0.2567], [0.9978, 0.225]] },
  truck: { size: [900, 1200], box: [0.0, 0.235, 0.9689, 0.3817], polygon: [[0.0, 0.235], [0.0, 0.6], [0.4289, 0.595], [0.44, 0.5683], [0.5689, 0.5633], [0.6067, 0.55], [0.6867, 0.5517], [0.7, 0.5883], [0.74, 0.6117], [0.8222, 0.6033], [0.8511, 0.615], [0.8733, 0.555], [0.9422, 0.5367], [0.9644, 0.5167], [0.9533, 0.4317], [0.9111, 0.425], [0.8556, 0.3683], [0.54, 0.3467], [0.2956, 0.245]] },
  board: { size: [720, 960], box: [0.2756, 0.6483, 0.3933, 0.2533], polygon: [[0.3356, 0.6483], [0.3289, 0.6767], [0.3022, 0.6817], [0.2911, 0.6933], [0.2911, 0.73], [0.2778, 0.7317], [0.2756, 0.8233], [0.2911, 0.8267], [0.2911, 0.855], [0.3111, 0.8717], [0.3111, 0.8917], [0.5467, 0.9], [0.6467, 0.895], [0.6467, 0.875], [0.6667, 0.86], [0.6667, 0.6933], [0.6467, 0.68], [0.6467, 0.6517]] },
  groceries: { size: [600, 800], box: [0.3356, 0.27, 0.6533, 0.37], polygon: [[0.9511, 0.2717], [0.82, 0.2733], [0.8111, 0.3317], [0.7556, 0.3533], [0.7022, 0.355], [0.6644, 0.3383], [0.5422, 0.335], [0.5267, 0.3783], [0.3489, 0.3733], [0.3533, 0.4533], [0.3356, 0.5783], [0.3511, 0.6317], [0.4667, 0.6383], [0.4956, 0.6083], [0.5156, 0.6083], [0.5511, 0.6367], [0.6756, 0.6283], [0.6822, 0.6], [0.7822, 0.6333], [0.9178, 0.6283], [0.9711, 0.59], [0.9867, 0.365]] },
  fruits: { size: [720, 960], box: [0.0, 0.07, 0.7311, 0.9], polygon: [[0.0, 0.07], [0.0, 0.6683], [0.0467, 0.715], [0.0689, 0.8383], [0.18, 0.9167], [0.2778, 0.9583], [0.5533, 0.965], [0.6133, 0.9167], [0.6822, 0.8917], [0.66, 0.8083], [0.7289, 0.6833], [0.6244, 0.4333], [0.6311, 0.39], [0.5756, 0.3333], [0.5111, 0.1333], [0.4756, 0.0883], [0.32, 0.11], [0.2956, 0.1433], [0.2, 0.185], [0.1267, 0.1567], [0.0467, 0.07]] },
};

/**
 * A thing tools/strip followed through a demo video with the app's own code (tools/strip/pack.py
 * packs it): from frame `start` on, its outline in every frame, `points` uint16 x,y pairs a
 * frame (0-65535 across the picture), base64. `label` is YOLO's name for it, when it's one of
 * YOLO's things.
 */
export type VideoThing = { label: string | null; start: number; data: string };
export type VideoTracks = { clip: string; fps: number; frames: number; size: [number, number]; every: number; points: number; things: VideoThing[] };

export type DemoScene = {
  key: string;
  /** Short caption shown on the virtual camera. */
  caption: string;
  asset: number;
  width: number;
  height: number;
  outline: Outline;
  /** Real MobileSAM outlines for the scripted points (precomputed for the web preview), named where no callout sits on them. */
  parts: { at: P; polygon: P[]; label?: string }[];
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
    suggestions: string[];
  };
  /**
   * A moving scene: the clip (15 fps, played on a loop), and everything the strip finds in it,
   * followed frame by frame by the app's own code (tools/strip; null until it has run).
   */
  video?: { source: number; tracks: VideoTracks | null };
};

/** A video scene's whole picture as its outline (nothing in particular is the subject). */
const WHOLE: Outline = { size: [640, 360], box: [0, 0, 1, 1], polygon: [[0, 0], [1, 0], [1, 1], [0, 1]] };

/** Footage: Intel IoT Devkit sample videos (CC BY 4.0), cut to 10 s at 640x360, 15 fps. */
function videoScene(key: string, caption: string, title: string, source: number, poster: number, tracks: VideoTracks | null, labels: string[]): DemoScene {
  return {
    key,
    caption,
    asset: poster,
    width: 640,
    height: 360,
    outline: WHOLE,
    parts: [],
    text: [],
    objects: [],
    labels,
    script: { title, summary: '', callouts: [], facts: [], steps: [], question: `What's in the ${title.toLowerCase()}?`, suggestions: [] },
    video: { source, tracks },
  };
}

export const DEMO_SCENES: DemoScene[] = [
  {
    key: 'cars',
    caption: 'Havana, a pink classic',
    asset: require('../../../assets/demo/cars.jpg'),
    width: 900,
    height: 1200,
    outline: OUTLINES.cars,
    parts: [{ at: [0.3, 0.33], polygon: [[0.4956, 0.3375], [0.44, 0.3317], [0.3422, 0.2983], [0.2678, 0.3083], [0.2278, 0.3333], [0.2078, 0.3808], [0.2211, 0.48], [0.2122, 0.5558], [0.2267, 0.6108], [0.2378, 0.6108], [0.2333, 0.555], [0.2422, 0.5408], [0.2678, 0.525], [0.2978, 0.5208], [0.3222, 0.5292], [0.3756, 0.5167], [0.5022, 0.5083]] }, { at: [0.62, 0.53], polygon: [[0.9989, 0.5133], [0.9678, 0.5083], [0.4856, 0.5125], [0.3256, 0.5317], [0.29, 0.5225], [0.25, 0.5358], [0.2378, 0.5542], [0.2422, 0.5642], [0.2711, 0.5475], [0.3078, 0.54], [0.9978, 0.5267]] }, { at: [0.48, 0.68], polygon: [[0.2078, 0.6425], [0.2089, 0.6558], [0.2289, 0.6792], [0.3422, 0.6983], [0.4967, 0.6825], [0.51, 0.6733], [0.5256, 0.6375], [0.5233, 0.6325], [0.5178, 0.64], [0.5133, 0.6375], [0.5133, 0.6308], [0.4822, 0.6], [0.4967, 0.6017], [0.5011, 0.61], [0.5167, 0.6075], [0.4678, 0.5858], [0.2511, 0.5867], [0.2422, 0.5892], [0.2422, 0.5933], [0.2511, 0.5958], [0.2489, 0.6183], [0.2244, 0.615]] }, { at: [0.93, 0.76], polygon: [[0.8933, 0.725], [0.8878, 0.7308], [0.8933, 0.8025], [0.8989, 0.8058], [0.9111, 0.8075], [0.9733, 0.8067], [0.9956, 0.8042], [0.9978, 0.7992], [0.9956, 0.7258], [0.9878, 0.7225], [0.9067, 0.7225]] }, { at: [0.62, 0.5], label: 'Hood', polygon: [[0.9956, 0.2792], [0.9678, 0.27], [0.59, 0.3125], [0.4978, 0.3342], [0.5044, 0.5075], [0.9911, 0.5017], [0.9978, 0.4875]] }, { at: [0.6, 0.42], label: 'Hood', polygon: [[0.9967, 0.28], [0.97, 0.2692], [0.5911, 0.3125], [0.4978, 0.3342], [0.5044, 0.5075], [0.9911, 0.5017], [0.9978, 0.4925]] }, { at: [0.7, 0.3], label: 'Hood', polygon: [[0.9967, 0.28], [0.96, 0.27], [0.59, 0.3125], [0.4978, 0.3342], [0.5044, 0.5058], [0.9922, 0.5]] }],
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
      suggestions: ["How do I open the hood?", "What engine might it have now?"],
    },
  },
  {
    key: 'truck',
    caption: 'A white pickup, curbside',
    asset: require('../../../assets/demo/truck.jpg'),
    width: 900,
    height: 1200,
    outline: OUTLINES.truck,
    parts: [{ at: [0.47, 0.37], polygon: [[0.4556, 0.3175], [0.4522, 0.3208], [0.4511, 0.3392], [0.4522, 0.34], [0.4533, 0.3492], [0.4556, 0.3525], [0.4578, 0.365], [0.4622, 0.3683], [0.47, 0.37], [0.4889, 0.37], [0.4967, 0.3675], [0.5, 0.3642], [0.5011, 0.36], [0.5, 0.3592], [0.5, 0.355], [0.4944, 0.345], [0.4933, 0.3358], [0.4922, 0.335], [0.4922, 0.3267], [0.4856, 0.3217], [0.4767, 0.3175], [0.4733, 0.3167], [0.4589, 0.3167]] }, { at: [0.33, 0.43], polygon: [[0.1222, 0.26], [0.1544, 0.3542], [0.1311, 0.3625], [0.1456, 0.4108], [0.1578, 0.5517], [0.5444, 0.5408], [0.5567, 0.4958], [0.55, 0.4008], [0.5222, 0.3533], [0.5033, 0.3592], [0.4967, 0.37], [0.4556, 0.3658], [0.44, 0.32], [0.2989, 0.2642]] }, { at: [0.79, 0.54], polygon: [[0.64, 0.4975], [0.6178, 0.5283], [0.6178, 0.56], [0.6244, 0.5642], [0.6289, 0.5958], [0.6567, 0.6225], [0.7211, 0.6442], [0.7678, 0.6458], [0.8178, 0.6375], [0.8356, 0.6308], [0.8489, 0.62], [0.8689, 0.59], [0.8722, 0.5517], [0.8467, 0.5108], [0.8144, 0.4808], [0.7756, 0.4683], [0.7211, 0.4667], [0.6856, 0.4758]] }, { at: [0.79, 0.52], polygon: [[0.64, 0.4975], [0.6167, 0.5283], [0.6178, 0.5608], [0.6233, 0.5633], [0.6289, 0.5958], [0.6567, 0.6225], [0.6956, 0.6383], [0.7222, 0.6442], [0.7667, 0.6458], [0.8178, 0.6375], [0.8356, 0.6308], [0.8489, 0.62], [0.8689, 0.59], [0.8722, 0.5517], [0.8478, 0.5125], [0.8144, 0.4808], [0.7756, 0.4683], [0.7222, 0.4667], [0.7011, 0.47]] }, { at: [0.8, 0.55], polygon: [[0.6411, 0.4967], [0.6167, 0.5292], [0.6167, 0.5542], [0.6233, 0.5633], [0.6289, 0.5958], [0.6556, 0.6217], [0.7033, 0.64], [0.7378, 0.6458], [0.7667, 0.6458], [0.8178, 0.6375], [0.8356, 0.6308], [0.8478, 0.6208], [0.8689, 0.5892], [0.8722, 0.5525], [0.8478, 0.5125], [0.8144, 0.4808], [0.7756, 0.4683], [0.7211, 0.4667], [0.7011, 0.47]] }],
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
      suggestions: ["How do I check the tyre pressure?", "Where is the spare wheel?"],
    },
  },
  {
    key: 'board',
    caption: 'An old sound card',
    asset: require('../../../assets/demo/board.jpg'),
    width: 720,
    height: 960,
    outline: OUTLINES.board,
    parts: [{ at: [0.47, 0.76], polygon: [[0.3028, 0.6854], [0.3028, 0.8615], [0.3083, 0.8667], [0.6556, 0.8688], [0.6542, 0.6865]] }, { at: [0.46, 0.39], polygon: [[0.4583, 0.3125], [0.4569, 0.325], [0.4375, 0.3333], [0.4347, 0.3646], [0.4167, 0.3677], [0.4194, 0.374], [0.4375, 0.3708], [0.4361, 0.3875], [0.4236, 0.3833], [0.4153, 0.4073], [0.4056, 0.4083], [0.4111, 0.4125], [0.3986, 0.4073], [0.3958, 0.4167], [0.4417, 0.4177], [0.4431, 0.4271], [0.4625, 0.4292], [0.5139, 0.4271], [0.525, 0.4354], [0.5333, 0.4302], [0.5444, 0.4458], [0.5333, 0.4667], [0.4403, 0.4688], [0.4208, 0.475], [0.5431, 0.4719], [0.5569, 0.4375], [0.5806, 0.475], [0.6861, 0.4719], [0.6847, 0.3365], [0.6569, 0.3458], [0.6194, 0.3208], [0.5694, 0.3115], [0.5528, 0.3146], [0.5389, 0.3052], [0.5333, 0.3104], [0.5222, 0.3042], [0.5167, 0.3115]] }, { at: [0.55, 0.24], polygon: [[0.5319, 0.2333], [0.5194, 0.2427], [0.5153, 0.25], [0.5139, 0.2604], [0.5194, 0.2708], [0.5347, 0.2802], [0.5375, 0.2802], [0.5417, 0.2823], [0.5542, 0.2833], [0.5556, 0.2823], [0.5625, 0.2823], [0.5681, 0.2802], [0.5764, 0.274], [0.5833, 0.2646], [0.5833, 0.25], [0.5792, 0.2427], [0.575, 0.2385], [0.5653, 0.2323], [0.5597, 0.2323], [0.5583, 0.2313], [0.5389, 0.2313], [0.5347, 0.2333]] }, { at: [0.24, 0.31], polygon: [[0.2153, 0.2958], [0.2111, 0.2979], [0.2111, 0.3177], [0.2097, 0.3187], [0.2097, 0.3344], [0.2083, 0.3354], [0.2083, 0.3406], [0.2097, 0.3417], [0.2097, 0.3646], [0.2153, 0.3688], [0.2264, 0.3688], [0.2333, 0.3667], [0.2389, 0.3667], [0.2417, 0.3656], [0.2431, 0.3625], [0.2444, 0.3031], [0.2403, 0.3], [0.2319, 0.299], [0.2264, 0.2969]] }],
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
      suggestions: ["How does the audio get to my speakers?", "What does the crystal do?"],
    },
  },
  {
    key: 'groceries',
    caption: 'Groceries in the trunk',
    asset: require('../../../assets/demo/groceries.jpg'),
    width: 600,
    height: 800,
    outline: OUTLINES.groceries,
    parts: [{ at: [0.72, 0.3], polygon: [[0.815, 0.2662], [0.815, 0.27], [0.8117, 0.2725], [0.7583, 0.2725], [0.7317, 0.2762], [0.7117, 0.2737], [0.7017, 0.2838], [0.7017, 0.3025], [0.7067, 0.35], [0.71, 0.3525], [0.74, 0.3538], [0.765, 0.3488], [0.805, 0.3475], [0.8217, 0.3438], [0.8333, 0.3375], [0.83, 0.3262], [0.8283, 0.2963]] }, { at: [0.84, 0.25], polygon: [[0.8467, 0.1875], [0.8333, 0.1975], [0.8183, 0.2225], [0.8183, 0.26], [0.8317, 0.2988], [0.8317, 0.3237], [0.835, 0.335], [0.8383, 0.3362], [0.8633, 0.3287], [0.8667, 0.3063], [0.865, 0.2412], [0.8683, 0.2087], [0.8633, 0.1963]] }, { at: [0.42, 0.5], polygon: [[0.3517, 0.3738], [0.3533, 0.45], [0.335, 0.5413], [0.3417, 0.61], [0.3533, 0.6325], [0.3617, 0.635], [0.475, 0.6362], [0.485, 0.6288], [0.5033, 0.5875], [0.53, 0.4425], [0.53, 0.3862], [0.4567, 0.3775]] }, { at: [0.55, 0.72], polygon: [[0.9967, 0.6725], [0.895, 0.6987], [0.0083, 0.705], [0.0, 0.74], [0.3733, 0.7412], [0.39, 0.7212], [0.3983, 0.7412], [0.7933, 0.7338], [0.9433, 0.7488], [0.995, 0.7312]] }],
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
      suggestions: ["How should I pack this so nothing tips over?", "What goes in the fridge first?"],
    },
  },
  {
    key: 'fruits',
    caption: 'Citrus, cut open',
    asset: require('../../../assets/demo/fruits.jpg'),
    width: 720,
    height: 960,
    outline: OUTLINES.fruits,
    parts: [{ at: [0.36, 0.33], polygon: [[0.3819, 0.2635], [0.3181, 0.2562], [0.3208, 0.2458], [0.3111, 0.2552], [0.2458, 0.251], [0.1569, 0.3135], [0.0972, 0.3927], [0.1056, 0.4615], [0.0639, 0.5104], [0.0653, 0.5542], [0.1139, 0.5448], [0.0667, 0.5375], [0.1222, 0.5354], [0.1236, 0.5198], [0.1458, 0.5177], [0.1542, 0.4844], [0.1625, 0.5115], [0.1736, 0.5135], [0.1667, 0.5], [0.2056, 0.5031], [0.2111, 0.4938], [0.2417, 0.5021], [0.2444, 0.5125], [0.2125, 0.524], [0.2639, 0.5344], [0.2583, 0.5417], [0.2778, 0.549], [0.2806, 0.5333], [0.3097, 0.5521], [0.2931, 0.5635], [0.3069, 0.5677], [0.2972, 0.5771], [0.3125, 0.5729], [0.3139, 0.55], [0.3361, 0.5708], [0.3736, 0.5719], [0.3708, 0.5625], [0.3444, 0.5604], [0.3833, 0.5302], [0.3597, 0.4865], [0.425, 0.451], [0.4319, 0.4198], [0.4139, 0.3688], [0.3528, 0.2927], [0.3722, 0.2865], [0.3542, 0.2625], [0.3806, 0.2708]] }, { at: [0.14, 0.4], polygon: [[0.2472, 0.251], [0.1639, 0.3073], [0.1069, 0.376], [0.0944, 0.4073], [0.1056, 0.4625], [0.0847, 0.4771], [0.0639, 0.5198], [0.1417, 0.5135], [0.1361, 0.4885], [0.1597, 0.5], [0.2056, 0.499], [0.2056, 0.5135], [0.2167, 0.5], [0.2222, 0.5156], [0.1764, 0.5292], [0.2417, 0.5208], [0.2694, 0.5344], [0.2903, 0.5302], [0.2889, 0.5167], [0.3056, 0.5177], [0.2972, 0.526], [0.3083, 0.5448], [0.3153, 0.5312], [0.3278, 0.5448], [0.3472, 0.5365], [0.3306, 0.5646], [0.3611, 0.5646], [0.3431, 0.5604], [0.3833, 0.526], [0.3597, 0.4865], [0.425, 0.4583], [0.4347, 0.4656], [0.4361, 0.4], [0.3708, 0.3094], [0.3542, 0.3031], [0.3528, 0.2927], [0.3861, 0.2781], [0.3708, 0.2833], [0.3514, 0.2698], [0.3667, 0.2625], [0.3819, 0.2698], [0.3833, 0.2625]] }, { at: [0.92, 0.38], polygon: [[0.9944, 0.2552], [0.8944, 0.2635], [0.8097, 0.2969], [0.7403, 0.3479], [0.6972, 0.4115], [0.6708, 0.4854], [0.6708, 0.5135], [0.7361, 0.6781], [0.8653, 0.5906], [0.9972, 0.5375]] }],
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
      suggestions: ["What is the cleanest way to peel this?", "How much vitamin C is in one?"],
    },
  },
];

// Moving scenes, for the strip: a finger slides between things that move and pins one.
DEMO_SCENES.push(
  videoScene('workers', 'Warehouse floor, moving', 'Warehouse floor', DEMO_VIDEO.workers, require('../../../assets/demo/video/workers.jpg'), require('../../../assets/demo/video/workers.tracks.json'), ['warehouse', 'person', 'safety vest']),
  videoScene('aisle', 'A store aisle, moving', 'Store aisle', DEMO_VIDEO.aisle, require('../../../assets/demo/video/aisle.jpg'), require('../../../assets/demo/video/aisle.tracks.json'), ['store', 'person', 'shelf']),
  videoScene('bottles', 'Bottles being moved', 'Bottles', DEMO_VIDEO.bottles, require('../../../assets/demo/video/bottles.jpg'), require('../../../assets/demo/video/bottles.tracks.json'), ['bottle', 'water', 'hand']),
);

export function sceneForUri(uri: string): DemoScene | null {
  const u = uri.toLowerCase();
  return DEMO_SCENES.find((s) => u.includes(`/${s.key}`) || u.includes(`${s.key}.`)) ?? null;
}

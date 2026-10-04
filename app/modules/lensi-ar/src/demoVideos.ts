// The demo videos' footage, by platform: iOS plays the H.264 files; the web preview gets VP9
// (demoVideos.web.ts), which every browser plays (Chromium without proprietary codecs doesn't
// play H.264). Same frames either way: the WebM files are made from the MP4s.
export const DEMO_VIDEO = {
  workers: require('../../../assets/demo/video/workers.mp4') as number,
  aisle: require('../../../assets/demo/video/aisle.mp4') as number,
  bottles: require('../../../assets/demo/video/bottles.mp4') as number,
};

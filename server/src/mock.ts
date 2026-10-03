import type { AnnotateBody } from "./prompt.js";

/**
 * A plausible, protocol-complete answer for LENSI_MOCK=1. It exercises every
 * line kind the app understands, so the app <-> server path can be tested
 * without a model or an API key.
 */
export function mockLines(body: AnnotateBody): string[] {
  const firstMark = body.marks?.match(/^(\d+):/m)?.[1];
  if (body.check) {
    return ["C|no|Turn it a little further, then check again."];
  }
  if (body.walkthrough && body.guide) {
    return [
      "T|Mock repair",
      "G|Turn off the power at the switch first.",
      firstMark ? `G|${firstMark}|marked part|Loosen the marked part by hand.` : "G|420|380|cover|Lift the cover off.",
      "G|610|720|drain cap|Unscrew the drain cap anticlockwise.",
    ];
  }
  if (body.walkthrough) {
    return [
      "T|Mock appliance",
      "W|420|380|Unplug it and let it cool for ten minutes.",
      firstMark ? `N|${firstMark}|Press the release on the marked part.` : "W|Press the release button.",
      "W|610|720|Lift the tray straight up.",
      "W|Rinse, dry and slide it back until it clicks.",
    ];
  }
  if (body.question) {
    return ["A|It looks like a mock appliance.", "A|The panel on the right holds the controls.", "P|700|300|controls"];
  }
  return [
    "T|Mock appliance",
    "S|A stand-in answer from the mock server.",
    "P|500|250|top panel",
    firstMark ? `M|${firstMark}|marked part` : "P|300|600|front",
    "F|Mock facts arrive one line at a time.",
    "F|Every line kind is exercised.",
    "Q|How do I clean it?",
    "Q|What is the marked part for?",
  ];
}

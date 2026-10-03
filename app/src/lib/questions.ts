const HOW_TO =
  /\b(how (do|can|to|would|should|does)|walk me|step[s ]|steps$|guide me|show me how|set ?up|install|assemble|replace|reset|clean|descale|fix|repair|turn (it )?(on|off)|open|close|connect|change|adjust|use (this|it)|(best|easiest|quickest|fastest|cleanest|simplest|safest|right|proper) way)\b/i;

/** Questions that want a walkthrough rather than an answer. */
export function isHowTo(q: string): boolean {
  return HOW_TO.test(q);
}

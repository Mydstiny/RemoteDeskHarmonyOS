/** Pure color math for the flowing Pro badge (kept apart from ArkUI for tests). */
// The iridescent cycle. A badge shows half a cycle across its width; the phase moves it.
const FLOW_CYCLE: string[] = ['#B9F3EA', '#CDC9FF', '#F4C8E5', '#F9E3B8'];
const FLOW_SPAN: number = 0.5;

function hexChannel(hex: string, index: number): number { return parseInt(hex.substring(1 + index * 2, 3 + index * 2), 16); }

function mixHex(from: string, to: string, amount: number): string {
  let result: string = '#';
  for (let index: number = 0; index < 3; index++) {
    const value: number = Math.round(hexChannel(from, index) + (hexChannel(to, index) - hexChannel(from, index)) * amount);
    const text: string = value.toString(16).toUpperCase();
    result += text.length < 2 ? '0' + text : text;
  }
  return result;
}

function cycleColor(position: number): string {
  const u: number = ((position % 1) + 1) % 1 * FLOW_CYCLE.length;
  const index: number = Math.floor(u);
  return mixHex(FLOW_CYCLE[index % FLOW_CYCLE.length], FLOW_CYCLE[(index + 1) % FLOW_CYCLE.length], u - index);
}

/**
 * Gradient stops for one frame: the cycle position at each edge plus every cycle color that
 * falls inside, so consecutive phases differ only slightly and the loop has no seam.
 */
export function proBadgeFlowStops(phase: number): Array<[ResourceColor, number]> {
  const stops: Array<[ResourceColor, number]> = [[cycleColor(phase), 0]];
  const start: number = phase * FLOW_CYCLE.length;
  const end: number = (phase + FLOW_SPAN) * FLOW_CYCLE.length;
  for (let k: number = Math.floor(start) + 1; k < end; k++) {
    const x: number = (k - start) / (end - start);
    if (x > 0 && x < 1) { stops.push([FLOW_CYCLE[k % FLOW_CYCLE.length], x]); }
  }
  stops.push([cycleColor(phase + FLOW_SPAN), 1]);
  return stops;
}

/** Accent presets and the app color picker use opaque #RRGGBB values. */
export function appUiButtonFill(accent: string): string {
  return /^#[a-fA-F0-9]{6}$/.test(accent) ? accent : '#007DFF';
}
function linearChannel(value: number): number {
  const channel = value / 255;
  return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
}
/** Choose the more legible of black and white without changing the saved accent.
 * Formula: W3C WCAG 2.2 relative luminance and contrast ratio. */
export function appUiButtonText(accent: string): string {
  const fill = appUiButtonFill(accent);
  const luminance = 0.2126 * linearChannel(parseInt(fill.substring(1, 3), 16)) +
    0.7152 * linearChannel(parseInt(fill.substring(3, 5), 16)) +
    0.0722 * linearChannel(parseInt(fill.substring(5, 7), 16));
  return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? '#000000' : '#FFFFFF';
}

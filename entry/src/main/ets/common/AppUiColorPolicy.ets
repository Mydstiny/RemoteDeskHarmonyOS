/** Accent presets and the app color picker use opaque #RRGGBB values. */
export function appUiButtonFill(accent: string): string {
  return /^#[a-fA-F0-9]{6}$/.test(accent) ? accent : '#007DFF';
}
function linearChannel(value: number): number {
  const channel = value / 255;
  return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
}
function relativeLuminance(fill: string): number {
  return 0.2126 * linearChannel(parseInt(fill.substring(1, 3), 16)) +
    0.7152 * linearChannel(parseInt(fill.substring(3, 5), 16)) +
    0.0722 * linearChannel(parseInt(fill.substring(5, 7), 16));
}
/** Choose the more legible of black and white without changing the saved accent.
 * Formula: W3C WCAG 2.2 relative luminance and contrast ratio. */
export function appUiButtonText(accent: string): string {
  const luminance = relativeLuminance(appUiButtonFill(accent));
  return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? '#000000' : '#FFFFFF';
}
/** Text on an accent fill in the settings: white, as it always was, unless white falls below 3:1 on a light
 * accent (yellow, light green, pastel pink…); then black. The default #007DFF keeps white (3.9:1). */
export function appUiOnAccentText(accent: string): string {
  const luminance = relativeLuminance(appUiButtonFill(accent));
  return 1.05 / (luminance + 0.05) >= 3 ? '#FFFFFF' : '#000000';
}

/**
 * The softer second line on an accent fill: the call site's own light tint over white text (unchanged on the default
 * blue), a dark grey over black text.
 */
export function accentSecondaryText(accent: string, whiteTint: string = '#EAF3FF'): string {
  return appUiOnAccentText(accent) === '#FFFFFF' ? whiteTint : '#3D3D3D';
}

/**
 * A translucent tint of a #RRGGBB colour. ArkUI reads eight hex digits as #AARRGGBB, so appending the alpha
 * (colour + '18') turned a light accent into an opaque, unrelated colour (mint → yellow).
 */
export function appUiTint(color: string, alpha: string): string {
  return /^#[0-9a-fA-F]{6}$/.test(color) && /^[0-9a-fA-F]{2}$/.test(alpha) ? '#' + alpha + color.substring(1) : color;
}

/** Accent-coloured text on a light surface: the accent while it reads there, otherwise the secondary text colour. */
export function appUiAccentTextOnSurface(accent: string, fallback: string): string {
  return appUiOnAccentText(accent) === '#FFFFFF' ? accent : fallback;
}

/**
 * Icons for Pro groups and workspaces. They are stored as `sym.<name>` text so they sync like any other field.
 * Groups and workspaces created before the symbol set stored emoji; those render as the closest symbol.
 */
export const PRO_SYMBOL_PREFIX: string = 'sym.';

/** Closest symbol for each emoji the earlier icon sets offered. */
const LEGACY_EMOJI_SYMBOLS: Record<string, string> = {
  '📁': 'sym.folder_fill', '🗂️': 'sym.folder_fill', '🗄️': 'sym.folder_fill', '💼': 'sym.doc',
  '🏠': 'sym.house_fill', '🏢': 'sym.computer_host_fill', '🖥️': 'sym.desktop_fill', '💻': 'sym.display',
  '⌨️': 'sym.keyboard', '🧑‍💻': 'sym.code_square', '🧪': 'sym.performance', '🔬': 'sym.performance',
  '📊': 'sym.performance', '🚀': 'sym.bolt_fill', '⚡': 'sym.bolt_fill', '🔥': 'sym.bolt_fill',
  '⚙️': 'sym.gearshape_fill', '🛠️': 'sym.gearshape_fill', '🔒': 'sym.lock_fill', '🔐': 'sym.lock_shield_fill',
  '☁️': 'sym.cloud_fill', '🌐': 'sym.link', '📡': 'sym.link', '🎮': 'sym.gamecontroller_fill',
  '🎬': 'sym.camera_fill', '🎨': 'sym.paintpalette_fill', '🧩': 'sym.list_bullet', '⭐': 'sym.star_fill',
  '🎯': 'sym.pin_fill', '🏷️': 'sym.pin_fill', '🧭': 'sym.pin_fill', '🌙': 'sym.moon_fill',
  '🌱': 'sym.sun_max_fill', '🌿': 'sym.sun_max_fill', '🍀': 'sym.sun_max_fill', '🌸': 'sym.paintpalette_fill',
  '☕': 'sym.timer', '📚': 'sym.doc', '🎧': 'sym.message', '🧠': 'sym.performance', '💡': 'sym.sun_max_fill',
  '🪐': 'sym.star_fill', '🌊': 'sym.cloud_fill', '🦊': 'sym.person_2_fill', '🐳': 'sym.person_2_fill'
};

/** The stored icon as a symbol key: symbol keys pass through, emoji map to their closest symbol. */
export function proSymbolKey(icon: string): string {
  if (icon.startsWith(PRO_SYMBOL_PREFIX)) { return icon; }
  const mapped: string | undefined = LEGACY_EMOJI_SYMBOLS[icon];
  return mapped !== undefined ? mapped : 'sym.folder_fill';
}

/** Maps a stored key to its system symbol; `$r` needs a literal per name. */
export function proSymbolResource(key: string): Resource | null {
  switch (key) {
    case 'sym.desktop_fill': return $r('sys.symbol.desktop_fill');
    case 'sym.display': return $r('sys.symbol.display');
    case 'sym.computer_host_fill': return $r('sys.symbol.computer_host_fill');
    case 'sym.keyboard': return $r('sys.symbol.keyboard');
    case 'sym.mouse': return $r('sys.symbol.mouse');
    case 'sym.code_square': return $r('sys.symbol.code_square');
    case 'sym.folder_fill': return $r('sys.symbol.folder_fill');
    case 'sym.house_fill': return $r('sys.symbol.house_fill');
    case 'sym.star_fill': return $r('sys.symbol.star_fill');
    case 'sym.bolt_fill': return $r('sys.symbol.bolt_fill');
    case 'sym.cloud_fill': return $r('sys.symbol.cloud_fill');
    case 'sym.lock_fill': return $r('sys.symbol.lock_fill');
    case 'sym.lock_shield_fill': return $r('sys.symbol.lock_shield_fill');
    case 'sym.checkmark_shield': return $r('sys.symbol.checkmark_shield');
    case 'sym.key_fill': return $r('sys.symbol.key_fill');
    case 'sym.gamecontroller_fill': return $r('sys.symbol.gamecontroller_fill');
    case 'sym.camera_fill': return $r('sys.symbol.camera_fill');
    case 'sym.paintpalette_fill': return $r('sys.symbol.paintpalette_fill');
    case 'sym.person_2_fill': return $r('sys.symbol.person_2_fill');
    case 'sym.envelope_fill': return $r('sys.symbol.envelope_fill');
    case 'sym.moon_fill': return $r('sys.symbol.moon_fill');
    case 'sym.sun_max_fill': return $r('sys.symbol.sun_max_fill');
    case 'sym.timer': return $r('sys.symbol.timer');
    case 'sym.hourglass': return $r('sys.symbol.hourglass');
    case 'sym.link': return $r('sys.symbol.link');
    case 'sym.pin_fill': return $r('sys.symbol.pin_fill');
    case 'sym.performance': return $r('sys.symbol.performance');
    case 'sym.doc': return $r('sys.symbol.doc');
    case 'sym.message': return $r('sys.symbol.message');
    case 'sym.rectangle_on_rectangle': return $r('sys.symbol.rectangle_on_rectangle');
    case 'sym.gearshape_fill': return $r('sys.symbol.gearshape_fill');
    case 'sym.list_bullet': return $r('sys.symbol.list_bullet');
    default: return null;
  }
}

/** A Pro icon drawn as a tinted system symbol; legacy emoji values show their closest symbol. */
@Component
export struct ProSymbolIcon {
  @Prop icon: string = '';
  @Prop glyphSize: number = 18;
  @Prop color: string = '#007DFF';

  build() {
    SymbolGlyph(proSymbolResource(proSymbolKey(this.icon)) ?? $r('sys.symbol.folder_fill'))
      .fontSize(this.glyphSize).fontColor([this.color])
  }
}

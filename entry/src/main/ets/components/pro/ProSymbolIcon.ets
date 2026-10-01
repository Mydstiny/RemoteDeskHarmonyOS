/**
 * Icons for Pro groups and workspaces. They are stored as `sym.<name>` text so they sync like any other field;
 * older emoji values still render as text.
 */
export const PRO_SYMBOL_PREFIX: string = 'sym.';

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

/** A Pro icon: system symbol in the given color, or the legacy emoji text. */
@Component
export struct ProSymbolIcon {
  @Prop icon: string = '';
  @Prop glyphSize: number = 18;
  @Prop color: string = '#007DFF';

  build() {
    if (proSymbolResource(this.icon) !== null) {
      SymbolGlyph(proSymbolResource(this.icon) as Resource).fontSize(this.glyphSize).fontColor([this.color])
    } else {
      Text(this.icon).fontSize(this.glyphSize)
    }
  }
}

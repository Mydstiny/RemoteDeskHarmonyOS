/**
 * Protocol identity icons shared by settings, host add flows and relay cards.
 *
 * Existing protocols keep their API 23 SymbolGlyph resources. Moonlight may
 * use its audited official-geometry asset on surfaces that support a branded
 * descriptor, with the original system symbol retained as a fail-safe.
 */
export type ProtocolIconKey =
  | 'rdp'
  | 'rustdesk'
  | 'ssh'
  | 'vnc'
  | 'moonlight'
  | 'rustdesk_relay'
  | 'vnc_gateway'
  | 'key_vault'
  | 'totp'
  | 'settings';

export type ProtocolIconKind = 'system' | 'brand';
export const MOONLIGHT_ICON_FALLBACK_SYMBOL: string = 'gamecontroller_fill';

export interface ProtocolIconDescriptor {
  kind: ProtocolIconKind;
  resource: Resource;
  fallback: Resource;
  fallbackName: string;
  tintable: boolean;
}

/** Single resource owner for the literal Moonlight fallback mapping. */
export function moonlightSystemFallbackIcon(): Resource {
  return $r('sys.symbol.gamecontroller_fill');
}

export function protocolIcon(key: ProtocolIconKey): Resource {
  switch (key) {
    case 'rdp':
      return $r('sys.symbol.desktop_fill');
    case 'rustdesk':
      return $r('sys.symbol.cloud_fill');
    case 'ssh':
      return $r('sys.symbol.code_square');
    case 'vnc':
      return $r('sys.symbol.display');
    case 'moonlight':
      return moonlightSystemFallbackIcon();
    case 'rustdesk_relay':
      return $r('sys.symbol.cloud_fill');
    case 'vnc_gateway':
      return $r('sys.symbol.display');
    case 'key_vault':
      return $r('sys.symbol.key_fill');
    case 'totp':
      return $r('sys.symbol.checkmark_shield');
    case 'settings':
      return $r('sys.symbol.gearshape_fill');
    default:
      return $r('sys.symbol.display');
  }
}

export function protocolIconDescriptor(key: ProtocolIconKey): ProtocolIconDescriptor {
  const fallback: Resource = protocolIcon(key);
  if (key === 'moonlight') {
    return {
      kind: 'brand',
      resource: $r('app.media.icon_moonlight'),
      fallback: fallback,
      fallbackName: MOONLIGHT_ICON_FALLBACK_SYMBOL,
      tintable: true
    };
  }
  return {
    kind: 'system',
    resource: fallback,
    fallback: fallback,
    fallbackName: '',
    tintable: true
  };
}

export function protocolIconLabel(key: ProtocolIconKey): string {
  switch (key) {
    case 'rdp': return 'RDP';
    case 'rustdesk': return 'RustDesk';
    case 'ssh': return 'SSH';
    case 'vnc': return 'VNC';
    case 'moonlight': return 'Moonlight';
    case 'rustdesk_relay': return 'RustDesk 中继';
    case 'vnc_gateway': return 'VNC Gateway';
    case 'key_vault': return '密钥保险库';
    case 'totp': return '2FA';
    case 'settings': return '设置';
    default: return '协议';
  }
}

/**
 * Protocol identity icons shared by settings, host add flows and relay cards.
 *
 * Keep protocol identity on API 23 SymbolGlyph resources.  This prevents a
 * raw SVG from silently becoming the visual owner of a protocol in one
 * surface while another surface uses a different icon family.
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

export function protocolIcon(key: ProtocolIconKey): Resource {
  switch (key) {
    case 'rdp':
      return $r('sys.symbol.desktop_fill');
    case 'rustdesk':
      return $r('sys.symbol.cloud_fill');
    case 'ssh':
      return $r('sys.symbol.desktop_fill');
    case 'vnc':
      return $r('sys.symbol.display');
    case 'moonlight':
      return $r('sys.symbol.gamecontroller_fill');
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

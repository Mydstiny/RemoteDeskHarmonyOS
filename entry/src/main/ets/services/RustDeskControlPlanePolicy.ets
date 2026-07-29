/**
 * RustDeskControlPlanePolicy — separate address-book HTTP access from relay
 * control-plane authentication.
 *
 * A Server Pro-compatible address-book API does not prove that the paired
 * hbbs/hbbr accepts the official Server Pro token contract.  Older relay
 * records therefore default to the key-only profile and must opt into token
 * handoff explicitly.
 */

export type RustDeskControlPlaneProfile =
  | 'oss_key_only'
  | 'addressbook_only_custom'
  | 'official_server_pro_token'
  | 'custom_control_plane';

export const RUSTDESK_CONTROL_PLANE_DEFAULT: RustDeskControlPlaneProfile = 'oss_key_only';
// This policy authorizes transient token handoff, so it is deliberately scoped
// to the current device rather than any synchronized relay record.
export const RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX: string =
  'rustdesk_control_plane_profile:';

const PROFILES: RustDeskControlPlaneProfile[] = [
  'oss_key_only',
  'addressbook_only_custom',
  'official_server_pro_token',
  'custom_control_plane'
];

export function normalizeRustDeskControlPlaneProfile(value: string | undefined): RustDeskControlPlaneProfile {
  if (value !== undefined && PROFILES.indexOf(value as RustDeskControlPlaneProfile) >= 0) {
    return value as RustDeskControlPlaneProfile;
  }
  return RUSTDESK_CONTROL_PLANE_DEFAULT;
}

export function rustDeskControlPlaneProfileMetadataKey(relayId: string): string {
  return relayId === '' ? '' : RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX + relayId;
}

export function rustDeskControlPlaneProfileLabel(profile: RustDeskControlPlaneProfile): string {
  switch (normalizeRustDeskControlPlaneProfile(profile)) {
    case 'official_server_pro_token': return 'Server Pro 控制面';
    case 'addressbook_only_custom': return '地址簿 API 兼容';
    case 'custom_control_plane': return '自定义控制面';
    default: return 'OSS Key-only';
  }
}

export function rustDeskControlPlaneProfileDescription(profile: RustDeskControlPlaneProfile): string {
  switch (normalizeRustDeskControlPlaneProfile(profile)) {
    case 'official_server_pro_token': return '向官方兼容的 rendezvous 控制面发送 Pro 会话令牌。';
    case 'addressbook_only_custom': return '令牌只用于地址簿 HTTP API，relay 连接按 OSS Key-only。';
    case 'custom_control_plane': return '仅在第三方明确兼容官方 token 契约并完成验证后启用。';
    default: return 'relay 只使用服务器公钥或 hbbs/hbbr 共享 Key，不发送地址簿令牌。';
  }
}

export function rustDeskControlPlaneProfileForRelayKind(kind: string): RustDeskControlPlaneProfile {
  if (kind === 'pro') { return 'official_server_pro_token'; }
  // "Advanced" chooses the form, not a verified third-party token contract.
  // Keep its default key-only until the user explicitly opts into that contract.
  if (kind === 'advanced') { return RUSTDESK_CONTROL_PLANE_DEFAULT; }
  return RUSTDESK_CONTROL_PLANE_DEFAULT;
}

export function rustDeskControlPlaneAllowsToken(profile: RustDeskControlPlaneProfile): boolean {
  const normalized = normalizeRustDeskControlPlaneProfile(profile);
  return normalized === 'official_server_pro_token' || normalized === 'custom_control_plane';
}

export function rustDeskControlPlaneTokenForConnection(
  profile: RustDeskControlPlaneProfile,
  direct: boolean,
  accessToken: string
): string {
  if (direct || accessToken.trim().length === 0 || !rustDeskControlPlaneAllowsToken(profile)) {
    return '';
  }
  return accessToken;
}

export function rustDeskControlPlaneRequiresAccount(profile: RustDeskControlPlaneProfile): boolean {
  return rustDeskControlPlaneAllowsToken(profile);
}

/**
 * RustDeskControlPlanePolicy — keeps transport keys, address-book HTTP
 * credentials and rendezvous control-plane credentials in distinct profiles.
 *
 * The profile is device-local authorization metadata. It is deliberately not
 * part of RustDeskRelayCloudJSON, because syncing a server address must never
 * authorize another device to send an HTTP token to hbbs/hbbr.
 */

export type RustDeskControlPlaneProfile =
  | 'oss_key_only'
  | 'oss_shared_access_key'
  | 'official_server_pro_token'
  | 'third_party_api_only'
  | 'third_party_control_plane'
  | 'direct_ip';

export type RustDeskControlPlaneCapabilitySource =
  | 'none'
  | 'official_server_pro'
  | 'verified_third_party';

export const RUSTDESK_CONTROL_PLANE_DEFAULT: RustDeskControlPlaneProfile =
  'oss_key_only';
export const RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX: string =
  'rustdesk_control_plane_profile:';

const PROFILES: RustDeskControlPlaneProfile[] = [
  'oss_key_only',
  'oss_shared_access_key',
  'official_server_pro_token',
  'third_party_api_only',
  'third_party_control_plane',
  'direct_ip'
];

/**
 * Legacy custom-control-plane rows are intentionally migrated to API-only.
 * An old UI choice is not proof that the paired rendezvous server implements
 * the official token contract.
 */
export function normalizeRustDeskControlPlaneProfile(
  value: string | undefined
): RustDeskControlPlaneProfile {
  if (value === 'addressbook_only_custom' ||
    value === 'custom_control_plane') {
    return 'third_party_api_only';
  }
  if (value !== undefined &&
    PROFILES.indexOf(value as RustDeskControlPlaneProfile) >= 0) {
    return value as RustDeskControlPlaneProfile;
  }
  return RUSTDESK_CONTROL_PLANE_DEFAULT;
}

export function rustDeskControlPlaneProfileForKeyMode(
  profile: RustDeskControlPlaneProfile,
  keyMode: string
): RustDeskControlPlaneProfile {
  const normalized: RustDeskControlPlaneProfile =
    normalizeRustDeskControlPlaneProfile(profile);
  if (normalized === 'oss_key_only' ||
    normalized === 'oss_shared_access_key') {
    return keyMode === 'shared_access_key'
      ? 'oss_shared_access_key' : 'oss_key_only';
  }
  return normalized;
}

export function rustDeskControlPlaneProfileMetadataKey(
  relayId: string
): string {
  return relayId === ''
    ? '' : RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX + relayId;
}

export function rustDeskControlPlaneProfileLabel(
  profile: RustDeskControlPlaneProfile
): string {
  switch (normalizeRustDeskControlPlaneProfile(profile)) {
    case 'oss_shared_access_key': return 'OSS 共享 -k';
    case 'official_server_pro_token': return '官方 Server Pro';
    case 'third_party_api_only': return '第三方地址簿 API';
    case 'third_party_control_plane': return '第三方控制面';
    case 'direct_ip': return 'Direct IP';
    default: return 'OSS 服务器公钥';
  }
}

export function rustDeskControlPlaneProfileDescription(
  profile: RustDeskControlPlaneProfile
): string {
  switch (normalizeRustDeskControlPlaneProfile(profile)) {
    case 'oss_shared_access_key':
      return '仅向 hbbs/hbbr licence_key 发送共享 -k，不发送地址簿令牌。';
    case 'official_server_pro_token':
      return '仅把同一中继下的官方 Server Pro 会话令牌发送到 rendezvous 控制面。';
    case 'third_party_api_only':
      return '令牌只用于第三方地址簿 HTTP API；连接按 OSS Key 模式执行。';
    case 'third_party_control_plane':
      return '只有本机完成协议能力验证后才允许向第三方 rendezvous 发送令牌。';
    case 'direct_ip':
      return '直接连接目标 IP，不使用地址簿或控制面令牌。';
    default:
      return '使用 Ed25519 服务器公钥验证身份，不发送地址簿令牌。';
  }
}

export function rustDeskControlPlaneProfileForRelayKind(
  kind: string
): RustDeskControlPlaneProfile {
  if (kind === 'pro') { return 'official_server_pro_token'; }
  if (kind === 'advanced') { return 'third_party_api_only'; }
  return RUSTDESK_CONTROL_PLANE_DEFAULT;
}

export function rustDeskControlPlaneAllowsToken(
  profile: RustDeskControlPlaneProfile,
  capabilitySource: RustDeskControlPlaneCapabilitySource = 'none'
): boolean {
  const normalized: RustDeskControlPlaneProfile =
    normalizeRustDeskControlPlaneProfile(profile);
  return (normalized === 'official_server_pro_token' &&
    capabilitySource === 'official_server_pro') ||
    (normalized === 'third_party_control_plane' &&
      capabilitySource === 'verified_third_party');
}

export function rustDeskControlPlaneTokenForConnection(
  profile: RustDeskControlPlaneProfile,
  direct: boolean,
  accessToken: string,
  capabilitySource: RustDeskControlPlaneCapabilitySource = 'none'
): string {
  if (direct || accessToken.trim().length === 0 ||
    !rustDeskControlPlaneAllowsToken(profile, capabilitySource)) {
    return '';
  }
  return accessToken;
}

export function rustDeskControlPlaneRequiresAccount(
  profile: RustDeskControlPlaneProfile
): boolean {
  const normalized: RustDeskControlPlaneProfile =
    normalizeRustDeskControlPlaneProfile(profile);
  return normalized === 'official_server_pro_token' ||
    normalized === 'third_party_control_plane';
}

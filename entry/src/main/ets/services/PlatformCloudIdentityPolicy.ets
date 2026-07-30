import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export type PlatformCloudIdentityProofState =
  'verified' | 'permission_denied' | 'not_logged_in' |
  'identity_unavailable' | 'identity_mismatch' |
  'platform_error';

/**
 * Opaque proof minted only from the current OS distributed-account API.
 * The raw platform account identifier is deliberately never persisted,
 * logged, or exposed to CloudStore.
 */
export interface PlatformCloudIdentityProof {
  state: PlatformCloudIdentityProofState;
  fingerprint: string;
  apiRevision: number;
}

function sha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({
    data: new util.TextEncoder().encode(value)
  });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    result += bytes[i].toString(16).padStart(2, '0');
  }
  return result;
}

export function unavailablePlatformCloudIdentityProof(
  state: PlatformCloudIdentityProofState = 'identity_unavailable'
): PlatformCloudIdentityProof {
  return { state, fingerprint: '', apiRevision: 23 };
}

export function platformCloudIdentityFingerprint(
  platformAccountId: string
): string {
  const normalized: string = platformAccountId.trim();
  if (normalized === '') { return ''; }
  return sha256Hex(
    'RemoteDeskHarmonyOS:platform-cloud-account:api23:v1:' +
    normalized);
}

export function platformCloudIdentityProofFromApi23(
  platformAccountId: string,
  loggedIn: boolean
): PlatformCloudIdentityProof {
  if (!loggedIn) {
    return unavailablePlatformCloudIdentityProof('not_logged_in');
  }
  const fingerprint: string =
    platformCloudIdentityFingerprint(platformAccountId);
  if (fingerprint === '') {
    return unavailablePlatformCloudIdentityProof(
      'identity_unavailable');
  }
  return {
    state: 'verified',
    fingerprint,
    apiRevision: 23
  };
}

/**
 * API 23 exposes no signed account-link object. Exact equality between the
 * freshly returned Account Kit UnionID and distributed-account id is
 * therefore the only acceptable correspondence proof. Any platform/build
 * where the two official APIs use different namespaces remains fail-closed.
 */
export function platformCloudIdentityMatchesAccountKit(
  accountKitUnionId: string,
  platformAccountId: string
): boolean {
  const accountKitId: string =
    accountKitUnionId.trim();
  const platformId: string =
    platformAccountId.trim();
  return accountKitId !== '' &&
    platformId !== '' &&
    accountKitId === platformId;
}

export function platformCloudIdentityProofIsValid(
  proof: PlatformCloudIdentityProof
): boolean {
  return proof.state === 'verified' &&
    proof.fingerprint.trim().length === 64 &&
    proof.apiRevision >= 23;
}

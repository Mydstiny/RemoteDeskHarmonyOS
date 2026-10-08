const REMOTE_HOST_EXTENSION_KEY: string =
  '_remoteDeskExtensionV1';

const DEVICE_LOCAL_TRUST_KEYS: string[] = [
  'sshhostkeyalgorithm',
  'sshhostkeyfingerprintsha256',
  'sshhostkeyrawbase64',
  'sshhostkeytrustedat',
  'sshhostkeytrustmode',
  'sshhostkeyrouteidentity',
  'rdpcertificatefingerprintsha256',
  'rdpcertificatesubject',
  'rdpcertificateissuer',
  'rdpcertificatecommonname',
  'rdpcertificatenotbeforems',
  'rdpcertificatenotafterms',
  'rdpcertificatetrustedat',
  'rdpcertificatetrustmode',
  'rdpcertificateallowuntrustedroot',
  'rdpcertificateallowhostmismatch',
  'rdpcertificaterouteidentity',
  'rdpgatewaycertificatefingerprintsha256',
  'rdpgatewaycertificatesubject',
  'rdpgatewaycertificateissuer',
  'rdpgatewaycertificatecommonname',
  'rdpgatewaycertificatenotbeforems',
  'rdpgatewaycertificatenotafterms',
  'rdpgatewaycertificatetrustedat',
  'rdpgatewaycertificatetrustmode',
  'rdpgatewaycertificateallowuntrustedroot',
  'rdpgatewaycertificateallowhostmismatch',
  'rdpgatewaycertificaterouteidentity'
];

/** Project only trust decisions that are owned by the current physical device. */
export function projectRemoteHostDeviceTrust(
  values: Record<string, string>
): Record<string, string> {
  const result: Record<string, string> = {};
  for (let i = 0; i < DEVICE_LOCAL_TRUST_KEYS.length; i++) {
    const key: string = DEVICE_LOCAL_TRUST_KEYS[i];
    if (values[key] !== undefined) {
      result[key] = values[key];
    }
  }
  return result;
}

/**
 * Reads the historical cloud extension only for the one-time local migration.
 * Normal cloud decoding never calls this function and therefore cannot adopt
 * another device's SSH/RDP trust decisions.
 */
export function extractLegacyRemoteHostDeviceTrust(
  displayConfigJson: string
): Record<string, string> {
  try {
    const root: Record<string, Object> =
      JSON.parse(displayConfigJson || '{}') as Record<string, Object>;
    const raw: Object | undefined =
      root[REMOTE_HOST_EXTENSION_KEY];
    if (!raw || typeof raw !== 'object') { return {}; }
    const values: Record<string, Object> =
      raw as Record<string, Object>;
    const normalized: Record<string, string> = {};
    for (let i = 0; i < DEVICE_LOCAL_TRUST_KEYS.length; i++) {
      const key: string = DEVICE_LOCAL_TRUST_KEYS[i];
      const value: Object | undefined = values[key];
      if (typeof value === 'string') {
        normalized[key] = value as string;
      } else if (typeof value === 'number') {
        normalized[key] = (value as number).toString();
      } else if (typeof value === 'boolean') {
        normalized[key] = value as boolean ? '1' : '0';
      }
    }
    return normalized;
  } catch (_e) {
    return {};
  }
}

/** Later sources win: physical columns < historical payload < local overlay. */
export function mergeRemoteHostDeviceTrust(
  physicalColumns: Record<string, string>,
  historicalPayload: Record<string, string>,
  localOverlay: Record<string, string>
): Record<string, string> {
  const result: Record<string, string> = {};
  const sources: Array<Record<string, string>> = [
    projectRemoteHostDeviceTrust(physicalColumns),
    projectRemoteHostDeviceTrust(historicalPayload),
    projectRemoteHostDeviceTrust(localOverlay)
  ];
  for (let i = 0; i < sources.length; i++) {
    const keys: string[] = Object.keys(sources[i]);
    for (let k = 0; k < keys.length; k++) {
      result[keys[k]] = sources[i][keys[k]];
    }
  }
  return result;
}

export function remoteHostDeviceTrustIsMeaningful(
  values: Record<string, string>
): boolean {
  const projected: Record<string, string> =
    projectRemoteHostDeviceTrust(values);
  const keys: string[] = Object.keys(projected);
  for (let i = 0; i < keys.length; i++) {
    const value: string = projected[keys[i]].trim();
    if (value !== '' && value !== '0' &&
      value.toLowerCase() !== 'false') {
      return true;
    }
  }
  return false;
}

/**
 * One device-trust decision: the keys that describe it, the key that says
 * whether it is trusted, the keys a restore resets to '0' so the decision
 * becomes a candidate that must be confirmed again, and the route binding a
 * restore clears so a candidate fingerprint can never act as a pin.
 */
interface RemoteHostDeviceTrustGroup {
  modeKey: string;
  keys: string[];
  candidateResetKeys: string[];
  routeKey: string;
}

const REMOTE_HOST_DEVICE_TRUST_GROUPS: RemoteHostDeviceTrustGroup[] = [
  {
    modeKey: 'sshhostkeytrustmode',
    keys: [
      'sshhostkeyalgorithm', 'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64',
      'sshhostkeytrustedat', 'sshhostkeytrustmode', 'sshhostkeyrouteidentity'
    ],
    candidateResetKeys: ['sshhostkeytrustmode', 'sshhostkeytrustedat'],
    routeKey: 'sshhostkeyrouteidentity'
  },
  {
    modeKey: 'sshjumphostkeytrustmode',
    keys: [
      'sshjumphostkeyalgorithm', 'sshjumphostkeyfingerprintsha256',
      'sshjumphostkeyrawbase64', 'sshjumphostkeytrustedat', 'sshjumphostkeytrustmode'
    ],
    candidateResetKeys: ['sshjumphostkeytrustmode', 'sshjumphostkeytrustedat'],
    routeKey: ''
  },
  {
    modeKey: 'rdpcertificatetrustmode',
    keys: [
      'rdpcertificatefingerprintsha256', 'rdpcertificatesubject', 'rdpcertificateissuer',
      'rdpcertificatecommonname', 'rdpcertificatenotbeforems', 'rdpcertificatenotafterms',
      'rdpcertificatetrustedat', 'rdpcertificatetrustmode',
      'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch',
      'rdpcertificaterouteidentity'
    ],
    candidateResetKeys: [
      'rdpcertificatetrustmode', 'rdpcertificatetrustedat',
      'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch'
    ],
    routeKey: 'rdpcertificaterouteidentity'
  },
  {
    modeKey: 'rdpgatewaycertificatetrustmode',
    keys: [
      'rdpgatewaycertificatefingerprintsha256', 'rdpgatewaycertificatesubject',
      'rdpgatewaycertificateissuer', 'rdpgatewaycertificatecommonname',
      'rdpgatewaycertificatenotbeforems', 'rdpgatewaycertificatenotafterms',
      'rdpgatewaycertificatetrustedat', 'rdpgatewaycertificatetrustmode',
      'rdpgatewaycertificateallowuntrustedroot', 'rdpgatewaycertificateallowhostmismatch',
      'rdpgatewaycertificaterouteidentity'
    ],
    candidateResetKeys: [
      'rdpgatewaycertificatetrustmode', 'rdpgatewaycertificatetrustedat',
      'rdpgatewaycertificateallowuntrustedroot', 'rdpgatewaycertificateallowhostmismatch'
    ],
    routeKey: 'rdpgatewaycertificaterouteidentity'
  }
];

/** Every SSH host/jump-host key and RDP/RD Gateway certificate trust key. */
export function remoteHostDeviceTrustKeys(): string[] {
  const result: string[] = [];
  for (let g = 0; g < REMOTE_HOST_DEVICE_TRUST_GROUPS.length; g++) {
    const keys: string[] = REMOTE_HOST_DEVICE_TRUST_GROUPS[g].keys;
    for (let k = 0; k < keys.length; k++) { result.push(keys[k]); }
  }
  return result;
}

/** Copy without any device-trust key (redacted backups, restored rows). */
export function withoutRemoteHostDeviceTrust(
  values: Record<string, string>
): Record<string, string> {
  const trustKeys: string[] = remoteHostDeviceTrustKeys();
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(values);
  for (let i = 0; i < keys.length; i++) {
    if (trustKeys.indexOf(keys[i]) < 0) { result[keys[i]] = values[keys[i]]; }
  }
  return result;
}

/**
 * Restored trust is never trusted (user decision 2026-10-04): every group
 * present in a full backup keeps its fingerprint and certificate details as
 * a reference, but its mode, trust time and host/root exceptions are reset
 * and its route binding is cleared (an RDP connection pins any fingerprint
 * whose route matches), so the first connection asks again like a new host.
 */
export function demoteRemoteHostDeviceTrust(
  values: Record<string, string>
): Record<string, string> {
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(values);
  for (let i = 0; i < keys.length; i++) { result[keys[i]] = values[keys[i]]; }
  for (let g = 0; g < REMOTE_HOST_DEVICE_TRUST_GROUPS.length; g++) {
    const group: RemoteHostDeviceTrustGroup = REMOTE_HOST_DEVICE_TRUST_GROUPS[g];
    let present: boolean = false;
    for (let k = 0; k < group.keys.length; k++) {
      if (values[group.keys[k]] !== undefined) { present = true; break; }
    }
    if (!present) { continue; }
    for (let k = 0; k < group.candidateResetKeys.length; k++) {
      result[group.candidateResetKeys[k]] = '0';
    }
    if (group.routeKey !== '') {
      result[group.routeKey] = '';
    }
  }
  return result;
}

function remoteHostDeviceTrustModeEstablished(value: string | undefined): boolean {
  if (value === undefined) { return false; }
  // Stored payloads are JSON; a corrupt non-string must not abort a restore.
  const trimmed: string = String(value).trim();
  return trimmed !== '' && trimmed !== '0';
}

/**
 * A restore never weakens trust this device already established: groups the
 * existing payload trusts are dropped from the incoming payload, so the merge
 * keeps the local decision; other groups take the restored candidate.
 */
export function mergeRestoredRemoteHostDeviceTrust(
  existing: Record<string, string>,
  incoming: Record<string, string>
): Record<string, string> {
  const dropped: string[] = [];
  for (let g = 0; g < REMOTE_HOST_DEVICE_TRUST_GROUPS.length; g++) {
    const group: RemoteHostDeviceTrustGroup = REMOTE_HOST_DEVICE_TRUST_GROUPS[g];
    if (remoteHostDeviceTrustModeEstablished(existing[group.modeKey])) {
      for (let k = 0; k < group.keys.length; k++) { dropped.push(group.keys[k]); }
    }
  }
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(incoming);
  for (let i = 0; i < keys.length; i++) {
    if (dropped.indexOf(keys[i]) < 0) { result[keys[i]] = incoming[keys[i]]; }
  }
  return result;
}

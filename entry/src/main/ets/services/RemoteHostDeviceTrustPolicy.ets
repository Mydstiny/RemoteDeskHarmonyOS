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

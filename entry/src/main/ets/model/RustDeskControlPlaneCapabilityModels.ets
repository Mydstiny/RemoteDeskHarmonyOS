/**
 * Device-local, non-secret evidence that one authenticated HTTP account is
 * explicitly bound to one rendezvous identity.  Only fingerprints are
 * persisted; API URLs, endpoints, public/shared keys and tokens are absent.
 */
export interface RustDeskControlPlaneCapabilityProof {
  schemaVersion: number
  source: string
  ownerScopeFingerprint: string
  accountIdFingerprint: string
  relayIdFingerprint: string
  tokenGeneration: number
  accessTokenFingerprint: string
  apiOriginFingerprint: string
  rendezvousEndpointFingerprint: string
  relayEndpointFingerprint: string
  serverIdentityFingerprint: string
  verifiedAt: number
}

export function cloneRustDeskControlPlaneCapabilityProof(
  proof: RustDeskControlPlaneCapabilityProof | undefined
): RustDeskControlPlaneCapabilityProof | undefined {
  if (proof === undefined) { return undefined; }
  return {
    schemaVersion: proof.schemaVersion,
    source: proof.source,
    ownerScopeFingerprint: proof.ownerScopeFingerprint,
    accountIdFingerprint: proof.accountIdFingerprint,
    relayIdFingerprint: proof.relayIdFingerprint,
    tokenGeneration: proof.tokenGeneration,
    accessTokenFingerprint: proof.accessTokenFingerprint,
    apiOriginFingerprint: proof.apiOriginFingerprint,
    rendezvousEndpointFingerprint: proof.rendezvousEndpointFingerprint,
    relayEndpointFingerprint: proof.relayEndpointFingerprint,
    serverIdentityFingerprint: proof.serverIdentityFingerprint,
    verifiedAt: proof.verifiedAt
  };
}

export function rustDeskControlPlaneCapabilityProofFromObject(
  value: Object | undefined
): RustDeskControlPlaneCapabilityProof | undefined {
  if (value === undefined || value === null ||
    typeof value !== 'object') {
    return undefined;
  }
  const row: Record<string, Object> =
    value as Record<string, Object>;
  const stringKeys: string[] = [
    'source', 'ownerScopeFingerprint', 'accountIdFingerprint',
    'relayIdFingerprint', 'accessTokenFingerprint',
    'apiOriginFingerprint', 'rendezvousEndpointFingerprint',
    'relayEndpointFingerprint', 'serverIdentityFingerprint'
  ];
  for (let i = 0; i < stringKeys.length; i++) {
    if (typeof row[stringKeys[i]] !== 'string' ||
      (row[stringKeys[i]] as string).trim() === '') {
      return undefined;
    }
  }
  if (typeof row['schemaVersion'] !== 'number' ||
    typeof row['tokenGeneration'] !== 'number' ||
    typeof row['verifiedAt'] !== 'number') {
    return undefined;
  }
  return {
    schemaVersion: row['schemaVersion'] as number,
    source: row['source'] as string,
    ownerScopeFingerprint: row['ownerScopeFingerprint'] as string,
    accountIdFingerprint: row['accountIdFingerprint'] as string,
    relayIdFingerprint: row['relayIdFingerprint'] as string,
    tokenGeneration: row['tokenGeneration'] as number,
    accessTokenFingerprint: row['accessTokenFingerprint'] as string,
    apiOriginFingerprint: row['apiOriginFingerprint'] as string,
    rendezvousEndpointFingerprint:
      row['rendezvousEndpointFingerprint'] as string,
    relayEndpointFingerprint: row['relayEndpointFingerprint'] as string,
    serverIdentityFingerprint: row['serverIdentityFingerprint'] as string,
    verifiedAt: row['verifiedAt'] as number
  };
}

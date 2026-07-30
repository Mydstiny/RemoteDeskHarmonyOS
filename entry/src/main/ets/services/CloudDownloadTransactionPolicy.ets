import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export type CloudDownloadTransactionOperation =
  'startup_bootstrap' | 'manual_download' |
  'selection_reenable' | 'vnc_scope_reenable';

export interface CloudDownloadTransactionEnvelope {
  version: number;
  operation: CloudDownloadTransactionOperation;
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
  createdAt: number;
  payloadSha256: string;
  payloadJson: string;
}

export const CLOUD_DOWNLOAD_TRANSACTION_VERSION: number = 1;
export const CLOUD_DOWNLOAD_TRANSACTION_MAX_BYTES: number =
  16 * 1024 * 1024;
export const CLOUD_DOWNLOAD_TRANSACTION_MAX_PAYLOAD_BYTES:
  number = 8 * 1024 * 1024;

function sha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(value) });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    result += bytes[i].toString(16).padStart(2, '0');
  }
  return result;
}

export function cloudDownloadTransactionEnvelope(
  operation: CloudDownloadTransactionOperation,
  ownerScopeId: string,
  storeIdentity: string,
  generation: number,
  payloadJson: string,
  now: number = Date.now()
): CloudDownloadTransactionEnvelope | null {
  if (ownerScopeId.trim() === '' ||
    storeIdentity.trim() === '' ||
    generation <= 0 ||
    payloadJson === '' ||
    new util.TextEncoder().encode(payloadJson).length >
      CLOUD_DOWNLOAD_TRANSACTION_MAX_PAYLOAD_BYTES) {
    return null;
  }
  return {
    version: CLOUD_DOWNLOAD_TRANSACTION_VERSION,
    operation,
    ownerScopeId,
    storeIdentity,
    generation: Math.floor(generation),
    createdAt: Math.max(1, Math.floor(now)),
    payloadSha256: sha256Hex(payloadJson),
    payloadJson
  };
}

export function parseCloudDownloadTransactionEnvelope(
  raw: string,
  ownerScopeId: string,
  storeIdentity: string,
  currentGeneration: number
): CloudDownloadTransactionEnvelope | null {
  if (raw === '' ||
    new util.TextEncoder().encode(raw).length >
      CLOUD_DOWNLOAD_TRANSACTION_MAX_BYTES) {
    return null;
  }
  try {
    const parsed: CloudDownloadTransactionEnvelope =
      JSON.parse(raw) as CloudDownloadTransactionEnvelope;
    if (parsed.version !==
      CLOUD_DOWNLOAD_TRANSACTION_VERSION ||
      (parsed.operation !== 'startup_bootstrap' &&
        parsed.operation !== 'manual_download' &&
        parsed.operation !== 'selection_reenable' &&
        parsed.operation !== 'vnc_scope_reenable') ||
      parsed.ownerScopeId !== ownerScopeId ||
      parsed.storeIdentity !== storeIdentity ||
      parsed.generation <= 0 ||
      parsed.generation > currentGeneration ||
      parsed.createdAt <= 0 ||
      parsed.payloadJson === '' ||
      parsed.payloadSha256.length !== 64 ||
      new util.TextEncoder().encode(parsed.payloadJson).length >
        CLOUD_DOWNLOAD_TRANSACTION_MAX_PAYLOAD_BYTES ||
      sha256Hex(parsed.payloadJson) !==
        parsed.payloadSha256) {
      return null;
    }
    return parsed;
  } catch (_error) {
    return null;
  }
}

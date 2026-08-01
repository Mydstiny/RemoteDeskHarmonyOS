import {
  RustDeskRelayJSON
} from '../model/RustDeskRelayConfig';
import { RustDeskAccountJSON } from '../model/RustDeskAccount';

const MAX_LEGACY_RELAYS: number = 2048;

function optionalStringIsValid(
  value: Object | undefined
): boolean {
  return value === undefined || typeof value === 'string';
}

function optionalNumberIsValid(
  value: Object | undefined
): boolean {
  return value === undefined ||
    (typeof value === 'number' && Number.isFinite(value as number));
}

function legacyAccountsAreValid(value: Object | undefined): boolean {
  if (value === undefined) { return true; }
  if (!Array.isArray(value)) { return false; }
  const accounts: Array<Record<string, Object>> =
    value as Array<Record<string, Object>>;
  for (let i = 0; i < accounts.length; i++) {
    const account: Record<string, Object> = accounts[i];
    if (!account || typeof account !== 'object' ||
      Array.isArray(account) ||
      !optionalStringIsValid(account['id']) ||
      !optionalStringIsValid(account['relayId']) ||
      !optionalStringIsValid(account['username']) ||
      !optionalStringIsValid(account['password']) ||
      !optionalStringIsValid(account['loginStatus']) ||
      !optionalNumberIsValid(account['lastLoginAt']) ||
      !optionalNumberIsValid(account['createdAt'])) {
      return false;
    }
  }
  return true;
}

function stringValue(
  row: Record<string, Object>, key: string,
  fallback: string = ''
): string {
  const value: Object | undefined = row[key];
  return typeof value === 'string' ? value as string : fallback;
}

function numberValue(
  row: Record<string, Object>, key: string,
  fallback: number = 0
): number {
  const value: Object | undefined = row[key];
  return typeof value === 'number' &&
    Number.isFinite(value as number)
    ? value as number : fallback;
}

function normalizedAccounts(
  value: Object | undefined
): RustDeskAccountJSON[] {
  if (!Array.isArray(value)) { return []; }
  const source: Array<Record<string, Object>> =
    value as Array<Record<string, Object>>;
  const result: RustDeskAccountJSON[] = [];
  for (let i = 0; i < source.length; i++) {
    result.push({
      id: stringValue(source[i], 'id'),
      relayId: stringValue(source[i], 'relayId'),
      username: stringValue(source[i], 'username'),
      password: stringValue(source[i], 'password'),
      loginStatus: stringValue(source[i], 'loginStatus', 'none'),
      lastLoginAt: numberValue(source[i], 'lastLoginAt'),
      createdAt: numberValue(source[i], 'createdAt')
    });
  }
  return result;
}

/**
 * Strictly parses the retired cryptoparams relay container. The caller owns
 * account injection and transactional insertion; this function never returns
 * partially accepted data.
 */
export function parseLegacyRelayJson(
  raw: string
): RustDeskRelayJSON[] | null {
  if (raw === '') { return []; }
  try {
    const parsed: Array<Record<string, Object>> =
      JSON.parse(raw) as Array<Record<string, Object>>;
    if (!Array.isArray(parsed) ||
      parsed.length > MAX_LEGACY_RELAYS) {
      return null;
    }
    const ids: Set<string> = new Set<string>();
    const result: RustDeskRelayJSON[] = [];
    for (let i = 0; i < parsed.length; i++) {
      const row: Record<string, Object> = parsed[i];
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        return null;
      }
      const idValue: Object | undefined = row['id'];
      if (typeof idValue !== 'string' ||
        (idValue as string).trim() === '' ||
        ids.has(idValue as string) ||
        !optionalStringIsValid(row['userId']) ||
        !optionalStringIsValid(row['idServer']) ||
        !optionalStringIsValid(row['relayServer']) ||
        !optionalStringIsValid(row['apiServer']) ||
        !optionalStringIsValid(row['apiUsername']) ||
        !optionalStringIsValid(row['apiPassword']) ||
        !optionalStringIsValid(row['key']) ||
        !optionalStringIsValid(row['healthStatus']) ||
        !optionalStringIsValid(row['apiLoginStatus']) ||
        !optionalNumberIsValid(row['idServerPort']) ||
        !optionalNumberIsValid(row['relayPort']) ||
        !optionalNumberIsValid(row['healthLatency']) ||
        !optionalNumberIsValid(row['healthCheckedAt']) ||
        !optionalNumberIsValid(row['syncVersion']) ||
        !optionalNumberIsValid(row['createdAt']) ||
        !optionalNumberIsValid(row['updatedAt']) ||
        !legacyAccountsAreValid(row['accounts'])) {
        return null;
      }
      ids.add(idValue as string);
      result.push({
        id: idValue as string,
        userId: stringValue(row, 'userId'),
        idServer: stringValue(row, 'idServer'),
        idServerPort: numberValue(row, 'idServerPort', 21116),
        relayServer: stringValue(row, 'relayServer'),
        relayPort: numberValue(row, 'relayPort', 21117),
        apiServer: stringValue(row, 'apiServer'),
        apiUsername: stringValue(row, 'apiUsername'),
        apiPassword: stringValue(row, 'apiPassword'),
        key: stringValue(row, 'key'),
        healthStatus: stringValue(row, 'healthStatus', 'unknown'),
        healthLatency: numberValue(row, 'healthLatency'),
        healthCheckedAt: numberValue(row, 'healthCheckedAt'),
        apiLoginStatus: stringValue(row, 'apiLoginStatus', 'none'),
        accounts: normalizedAccounts(row['accounts']),
        syncVersion: numberValue(row, 'syncVersion'),
        createdAt: numberValue(row, 'createdAt'),
        updatedAt: numberValue(row, 'updatedAt')
      });
    }
    return result;
  } catch (_e) {
    return null;
  }
}

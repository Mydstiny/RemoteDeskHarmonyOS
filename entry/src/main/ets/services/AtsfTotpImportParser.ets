import { TotpEntry, TotpAlgorithm } from '../model/TotpEntry';
import { TotpEngine } from './TotpEngine';

export interface AtsfTotpParseResult {
  ok: boolean
  entries: TotpEntry[]
  error: string
}

function importedAlgorithm(value: string): TotpAlgorithm {
  const normalized = value.toUpperCase();
  if (normalized === 'SHA256') { return TotpAlgorithm.SHA256; }
  if (normalized === 'SHA512') { return TotpAlgorithm.SHA512; }
  return TotpAlgorithm.SHA1;
}

/** Converts the legacy ATSF/JSON account shape used by this app into the current model. */
export function totpEntryFromImportObject(value: Object): TotpEntry | null {
  if (!value || typeof value !== 'object') { return null; }
  const row = value as Record<string, Object>;
  const uri = typeof row['uri'] === 'string' ? row['uri'] as string : '';
  if (uri.startsWith('otpauth://')) { return TotpEngine.parseOtpAuthUri(uri); }
  const issuer = typeof row['issuer'] === 'string' ? row['issuer'] as string : '';
  const accountValue = row['account'] ?? row['accountName'] ?? row['name'];
  const account = typeof accountValue === 'string' ? accountValue as string : '';
  const secretValue = row['secret'] ?? row['secretBase32'];
  const secret = typeof secretValue === 'string'
    ? (secretValue as string).replace(/\s+/g, '').toUpperCase() : '';
  if (issuer.length === 0 || secret.length === 0 || !/^[A-Z2-7]+=*$/.test(secret)) { return null; }
  const entry = new TotpEntry();
  entry.id = TotpEntry.generateId(); entry.issuer = issuer; entry.account = account; entry.secret = secret;
  const digitsValue = row['digits']; const periodValue = row['period'];
  entry.digits = typeof digitsValue === 'number' && digitsValue === 8 ? 8 : 6;
  entry.period = typeof periodValue === 'number' && periodValue === 60 ? 60 : 30;
  const algorithmValue = row['algorithm'];
  if (typeof algorithmValue === 'string') { entry.algorithm = importedAlgorithm(algorithmValue); }
  return entry;
}

/** Parser for the app's ATSF JSON container. Missing version means the released legacy v1 shape. */
export class AtsfTotpImportParser {
  parse(text: string): AtsfTotpParseResult {
    try {
      const parsed = JSON.parse(text) as Object;
      let rows: Object[] = [];
      if (Array.isArray(parsed)) { rows = parsed as Object[]; }
      else {
        const root = parsed as Record<string, Object>;
        if (typeof root['version'] === 'number' && (root['version'] as number) > 1) {
          return this.failure('不支持的 ATSF 版本: ' + (root['version'] as number).toString());
        }
        if (root['encrypted'] === true || typeof root['ciphertext'] === 'string') {
          return this.failure('该 ATSF 使用了当前版本不支持的加密格式');
        }
        const value = root['entries'] ?? root['accounts'] ?? root['items'];
        if (Array.isArray(value)) { rows = value as Object[]; }
      }
      const entries: TotpEntry[] = [];
      for (let i = 0; i < rows.length; i++) {
        const entry = totpEntryFromImportObject(rows[i]);
        if (entry !== null) { entries.push(entry); }
      }
      return entries.length > 0
        ? { ok: true, entries, error: '' }
        : this.failure('ATSF 中没有有效账户');
    } catch (_err) {
      return this.failure('ATSF 文件损坏或不是支持的 JSON 结构');
    }
  }

  private failure(error: string): AtsfTotpParseResult { return { ok: false, entries: [], error }; }
}

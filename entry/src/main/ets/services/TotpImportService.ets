import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { TotpEntry, TotpAlgorithm } from '../model/TotpEntry';
import { TotpEngine } from './TotpEngine';
import {
  AtsfTotpImportParser,
  AtsfTotpParseResult,
  totpEntryFromImportObject
} from './AtsfTotpImportParser';

export interface TotpImportResult {
  ok: boolean
  fileName: string
  format: string
  entries: TotpEntry[]
  error: string
}

export function totpImportFileName(uri: string): string {
  let value: string = uri;
  const query = value.indexOf('?');
  if (query >= 0) { value = value.substring(0, query); }
  const slash = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
  let name = slash >= 0 ? value.substring(slash + 1) : value;
  try { name = decodeURIComponent(name); } catch (_err) { /* keep URI tail */ }
  return name.length > 0 ? name : '2fa-import.atsf';
}

export class TotpImportService {
  static readonly MAX_FILE_SIZE: number = 4 * 1024 * 1024;
  private atsfParser = new AtsfTotpImportParser();

  async pickAndParse(): Promise<TotpImportResult | null> {
    let file: fileIo.File | null = null;
    try {
      const options = new picker.DocumentSelectOptions();
      const uris = await new picker.DocumentViewPicker().select(options);
      if (uris.length === 0) { return null; }
      const uri = uris[0];
      const fileName = totpImportFileName(uri);
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size = fileIo.statSync(file.fd).size;
      if (size <= 0 || size > TotpImportService.MAX_FILE_SIZE) {
        fileIo.closeSync(file); file = null;
        return this.failure(fileName, size <= 0 ? '文件为空' : '文件超过 4 MB 限制');
      }
      const buffer = new ArrayBuffer(size);
      const read = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file); file = null;
      if (read !== size) { return this.failure(fileName, '文件读取不完整'); }
      const text = new util.TextDecoder().decodeToString(new Uint8Array(buffer)).replace(/^\uFEFF/, '');
      return this.parse(fileName, text);
    } catch (err) {
      if (file !== null) { try { fileIo.closeSync(file); } catch (_closeErr) { /* ignore */ } }
      return this.failure('', '文件读取失败: ' + JSON.stringify(err));
    }
  }

  parse(fileName: string, text: string): TotpImportResult {
    const lower = fileName.toLowerCase();
    if (lower.endsWith('.csv')) { return this.parseCsv(fileName, text); }
    if (lower.endsWith('.txt')) { return this.parseText(fileName, text); }
    if (lower.endsWith('.atsf')) { return this.parseAtsf(fileName, text); }
    if (lower.endsWith('.json')) { return this.parseJson(fileName, text); }
    const trimmed = text.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) { return this.parseJson(fileName, text); }
    if (trimmed.indexOf('otpauth://') >= 0) { return this.parseText(fileName, text); }
    return this.failure(fileName, '不支持的文件格式，请选择 ATSF、TXT、JSON 或 CSV');
  }

  private parseText(fileName: string, text: string): TotpImportResult {
    const lines = text.split(/\r?\n/);
    const entries: TotpEntry[] = [];
    for (let i = 0; i < lines.length; i++) {
      const start = lines[i].indexOf('otpauth://');
      if (start < 0) { continue; }
      const entry = TotpEngine.parseOtpAuthUri(lines[i].substring(start).trim());
      if (entry !== null) { entries.push(entry); }
    }
    return entries.length > 0 ? this.success(fileName, 'TXT', entries) : this.failure(fileName, '没有识别到有效的 otpauth 配置');
  }

  private parseCsv(fileName: string, text: string): TotpImportResult {
    const lines = text.split(/\r?\n/).filter((line: string): boolean => line.trim().length > 0);
    if (lines.length < 2) { return this.failure(fileName, 'CSV 没有账户数据'); }
    const headers = this.csvColumns(lines[0]).map((value: string): string => value.trim().toLowerCase());
    const entries: TotpEntry[] = [];
    for (let i = 1; i < lines.length; i++) {
      const values = this.csvColumns(lines[i]);
      const issuer = this.csvValue(headers, values, 'issuer');
      const account = this.csvValue(headers, values, 'account');
      const secret = this.csvValue(headers, values, 'secret').replace(/\s+/g, '');
      if (issuer.length === 0 || secret.length === 0) { continue; }
      const entry = new TotpEntry();
      entry.id = TotpEntry.generateId(); entry.issuer = issuer; entry.account = account; entry.secret = secret;
      const digits = parseInt(this.csvValue(headers, values, 'digits'));
      const period = parseInt(this.csvValue(headers, values, 'period'));
      entry.digits = digits === 8 ? 8 : 6; entry.period = period === 60 ? 60 : 30;
      entry.algorithm = this.algorithm(this.csvValue(headers, values, 'algorithm'));
      entries.push(entry);
    }
    return entries.length > 0 ? this.success(fileName, 'CSV', entries) : this.failure(fileName, 'CSV 中没有有效账户');
  }

  private csvColumns(line: string): string[] {
    const values: string[] = [];
    let current = ''; let quoted = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') {
        if (quoted && i + 1 < line.length && line[i + 1] === '"') { current += '"'; i++; }
        else { quoted = !quoted; }
      } else if (ch === ',' && !quoted) { values.push(current); current = ''; }
      else { current += ch; }
    }
    values.push(current);
    return values;
  }

  private csvValue(headers: string[], values: string[], name: string): string {
    const index = headers.indexOf(name);
    return index >= 0 && index < values.length ? values[index].trim() : '';
  }

  private parseAtsf(fileName: string, text: string): TotpImportResult {
    const parsed: AtsfTotpParseResult = this.atsfParser.parse(text);
    return parsed.ok ? this.success(fileName, 'ATSF', parsed.entries) : this.failure(fileName, parsed.error);
  }

  private parseJson(fileName: string, text: string): TotpImportResult {
    try {
      const parsed = JSON.parse(text) as Object;
      let rows: Object[] = [];
      if (Array.isArray(parsed)) { rows = parsed as Object[]; }
      else {
        const root = parsed as Record<string, Object>;
        const value = root['entries'] ?? root['accounts'] ?? root['items'];
        if (Array.isArray(value)) { rows = value as Object[]; }
      }
      const entries: TotpEntry[] = [];
      for (let i = 0; i < rows.length; i++) {
        const entry = totpEntryFromImportObject(rows[i]);
        if (entry !== null) { entries.push(entry); }
      }
      return entries.length > 0 ? this.success(fileName, 'JSON', entries) : this.failure(fileName, 'JSON 中没有有效账户');
    } catch (_err) {
      return this.failure(fileName, 'JSON 文件损坏');
    }
  }

  private algorithm(value: string): TotpAlgorithm {
    const normalized = value.toUpperCase();
    if (normalized === 'SHA256') { return TotpAlgorithm.SHA256; }
    if (normalized === 'SHA512') { return TotpAlgorithm.SHA512; }
    return TotpAlgorithm.SHA1;
  }

  private success(fileName: string, format: string, entries: TotpEntry[]): TotpImportResult {
    return { ok: true, fileName, format, entries, error: '' };
  }

  private failure(fileName: string, error: string): TotpImportResult {
    return { ok: false, fileName, format: '', entries: [], error };
  }
}

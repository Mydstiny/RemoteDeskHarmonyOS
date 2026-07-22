/**
 * RustDesk 客户端服务器配置导入。
 *
 * 官方客户端导出的分享串是：
 *   base64url(JSON({ host, relay, api, key })) 再整体反转
 * 同时兼容旧版直接导出的 JSON 文本。文件扩展名不是协议的一部分，
 * 所以这里按内容识别，允许用户导入从其他 RustDesk 客户端复制保存的任意文件。
 */
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface RustDeskRelayImportResult {
  ok: boolean;
  fileName: string;
  idServer: string;
  idServerPort: number;
  relayServer: string;
  relayPort: number;
  apiServer: string;
  key: string;
  error: string;
}

interface RustDeskExportObject {
  host?: string;
  relay?: string;
  api?: string;
  key?: string;
  idServer?: string;
  relayServer?: string;
  apiServer?: string;
}

class RustDeskEndpoint {
  host: string = '';
  port: number = 0;
  valid: boolean = true;
}

function fileNameFromUri(uri: string): string {
  let value = uri;
  const query = value.indexOf('?');
  if (query >= 0) { value = value.substring(0, query); }
  const slash = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
  let name = slash >= 0 ? value.substring(slash + 1) : value;
  try { name = decodeURIComponent(name); } catch (_err) { /* keep URI tail */ }
  return name.trim() === '' ? 'rustdesk-server-config' : name.trim();
}

function reverse(value: string): string {
  return value.split('').reverse().join('');
}

function endpoint(value: string, defaultPort: number): RustDeskEndpoint {
  const input = value.trim();
  const result = new RustDeskEndpoint();
  if (input.startsWith('[')) {
    const end = input.indexOf(']');
    if (end > 0) {
      const suffix = input.substring(end + 1);
      const port = suffix.startsWith(':') ? parseInt(suffix.substring(1)) : defaultPort;
      result.host = input.substring(1, end); result.port = port;
      result.valid = (suffix === '' || suffix.startsWith(':')) && !isNaN(port) && port > 0 && port <= 65535;
      return result;
    }
    result.valid = false; return result;
  }
  const colon = input.lastIndexOf(':');
  if (colon > 0 && input.indexOf(':') === colon) {
    const port = parseInt(input.substring(colon + 1));
    if (!isNaN(port) && port > 0 && port <= 65535) {
      result.host = input.substring(0, colon); result.port = port; return result;
    }
    result.valid = false; return result;
  }
  result.host = input; result.port = defaultPort; return result;
}

export class RustDeskRelayImportService {
  static readonly MAX_FILE_SIZE: number = 256 * 1024;

  async pickAndParse(): Promise<RustDeskRelayImportResult | null> {
    let file: fileIo.File | null = null;
    try {
      const uris: string[] = await new picker.DocumentViewPicker().select(new picker.DocumentSelectOptions());
      if (uris.length === 0) { return null; }
      const uri = uris[0];
      const fileName = fileNameFromUri(uri);
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size = fileIo.statSync(file.fd).size;
      if (size <= 0 || size > RustDeskRelayImportService.MAX_FILE_SIZE) {
        fileIo.closeSync(file); file = null;
        return this.failure(fileName, size <= 0 ? '配置文件为空' : '配置文件超过 256 KB 限制');
      }
      const buffer = new ArrayBuffer(size);
      const read = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file); file = null;
      if (read !== size) { return this.failure(fileName, '配置文件读取不完整'); }
      const text = new util.TextDecoder().decodeToString(new Uint8Array(buffer)).replace(/^\uFEFF/, '').trim();
      return this.parse(fileName, text);
    } catch (err) {
      if (file !== null) { try { fileIo.closeSync(file); } catch (_closeErr) { /* ignore */ } }
      return this.failure('', '配置文件读取失败: ' + JSON.stringify(err));
    }
  }

  parse(fileName: string, text: string): RustDeskRelayImportResult {
    let object: RustDeskExportObject | null = this.parseJson(text);
    if (object === null) {
      const encoded = reverse(text).replace(/-/g, '+').replace(/_/g, '/');
      const padded = encoded + '='.repeat((4 - encoded.length % 4) % 4);
      try {
        const bytes = new util.Base64Helper().decodeSync(padded);
        const decoded = new util.TextDecoder().decodeToString(bytes).trim();
        object = this.parseJson(decoded);
      } catch (_err) { object = null; }
    }
    if (object === null) { return this.failure(fileName, '无法识别 RustDesk 导出配置，请选择客户端“导出服务器配置”生成的内容'); }

    const rawId = (object.host ?? object.idServer ?? '').trim();
    const rawRelay = (object.relay ?? object.relayServer ?? '').trim();
    if (rawId.length === 0) { return this.failure(fileName, '导出配置缺少 ID 服务器'); }
    const id = endpoint(rawId, 21116);
    if (!id.valid || id.host.trim().length === 0) {
      return this.failure(fileName, 'ID 服务器地址或端口无效');
    }
    // RustDesk 官方允许 Relay 留空，客户端会按 ID 服务器推导；本地模型要求地址，
    // 因此只在导入结果中显式回填同一主机，用户仍可在预览表单中修改。
    const relay = endpoint(rawRelay.length > 0 ? rawRelay : id.host, 21117);
    if (!relay.valid || relay.host.trim().length === 0) {
      return this.failure(fileName, 'Relay 服务器地址或端口无效');
    }
    return {
      ok: true, fileName, idServer: id.host, idServerPort: id.port,
      relayServer: relay.host, relayPort: relay.port,
      // `key` can be hbbs/hbbr's arbitrary shared access text.  Trim only
      // endpoint fields; changing even one leading '=' or whitespace byte in
      // the key makes the server reject its licence_key comparison.
      apiServer: (object.api ?? object.apiServer ?? '').trim(), key: (object.key ?? ''), error: ''
    };
  }

  private parseJson(text: string): RustDeskExportObject | null {
    try {
      const value = JSON.parse(text) as RustDeskExportObject;
      if (value !== null && typeof value === 'object') {
        const hasField = typeof value.host === 'string' || typeof value.idServer === 'string' ||
          typeof value.relay === 'string' || typeof value.relayServer === 'string';
        if (hasField) { return value; }
      }
    } catch (_err) { /* try official reversed base64 format */ }
    return null;
  }

  private failure(fileName: string, error: string): RustDeskRelayImportResult {
    return { ok: false, fileName, idServer: '', idServerPort: 21116, relayServer: '', relayPort: 21117,
      apiServer: '', key: '', error };
  }
}

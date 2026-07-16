/**
 * SshKeyImportService — SSH 私钥文件选择、文本规范化和密钥元数据构造。
 *
 * 文件选择只返回内存中的临时文本；真正保存仍必须经过 KeyVaultService。
 */
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SshKey, SshKeyType } from '../model/SshKey';
import { ExtensionLoader } from './ExtensionLoader';
import { SshPrivateKeyInfo } from '../types/rdpnapi';

export interface SshKeyImportResult {
  ok: boolean;
  key: SshKey | null;
  fileName: string;
  error: string;
}

export function normalizeSshPrivateKeyText(text: string): string {
  return text.replace(/^\uFEFF/, '').trim();
}

export function sshKeyFileName(uri: string): string {
  let value: string = uri;
  const queryIndex: number = value.indexOf('?');
  if (queryIndex >= 0) { value = value.substring(0, queryIndex); }
  const slashIndex: number = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
  let name: string = slashIndex >= 0 ? value.substring(slashIndex + 1) : value;
  try { name = decodeURIComponent(name); } catch (_e) { /* keep the URI tail */ }
  return name.trim() === '' ? 'ssh-private-key' : name.trim();
}

export function sshKeyTypeFromNative(keyType: string): SshKeyType {
  const normalized: string = keyType.toLowerCase();
  if (normalized.indexOf('rsa') >= 0) { return SshKeyType.RSA; }
  if (normalized.indexOf('ecdsa') >= 0 || normalized.indexOf('ec') >= 0) {
    return SshKeyType.ECDSA;
  }
  if (normalized.indexOf('dsa') >= 0) { return SshKeyType.DSA; }
  return SshKeyType.ED25519;
}

export function buildSshKeyFromInspection(label: string, privateKey: string, info: SshPrivateKeyInfo): SshKey {
  const key: SshKey = new SshKey();
  key.id = SshKey.generateId();
  key.label = label.trim() === '' ? 'ssh-private-key' : label.trim();
  key.keyType = sshKeyTypeFromNative(info.keyType);
  key.privateKey = privateKey;
  key.publicKey = info.ok ? info.publicKeyOpenSsh : '';
  key.fingerprint = info.ok ? info.fingerprintSha256 : '';
  key.privateKeyEncrypted = info.encrypted;
  key.formatVersion = 1;
  return key;
}

export class SshKeyImportService {
  static readonly MAX_FILE_SIZE: number = 2 * 1024 * 1024;
  private loader: ExtensionLoader = ExtensionLoader.getInstance();

  async pickAndInspect(): Promise<SshKeyImportResult | null> {
    let file: fileIo.File | null = null;
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await viewPicker.select(options);
      if (uris.length === 0) { return null; }

      const uri: string = uris[0];
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      if (size <= 0) {
        fileIo.closeSync(file);
        file = null;
        return { ok: false, key: null, fileName: sshKeyFileName(uri), error: '[CC-SSHKEY-01] 私钥文件为空' };
      }
      if (size > SshKeyImportService.MAX_FILE_SIZE) {
        fileIo.closeSync(file);
        file = null;
        return { ok: false, key: null, fileName: sshKeyFileName(uri), error: '[CC-SSHKEY-01] 私钥文件超过 2 MB 限制' };
      }

      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const readSize: number = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      file = null;
      if (readSize !== size) {
        return { ok: false, key: null, fileName: sshKeyFileName(uri), error: '[CC-SSHKEY-01] 私钥文件读取不完整' };
      }
      const text: string = new util.TextDecoder().decodeToString(new Uint8Array(buffer));
      return this.inspectText(sshKeyFileName(uri), text);
    } catch (err) {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_closeErr) { /* ignore */ }
      }
      return {
        ok: false,
        key: null,
        fileName: '',
        error: '[CC-SSHKEY-01] 私钥文件读取失败: ' + JSON.stringify(err)
      };
    }
  }

  inspectText(label: string, text: string): SshKeyImportResult {
    const normalized: string = normalizeSshPrivateKeyText(text);
    if (normalized === '') {
      return { ok: false, key: null, fileName: label, error: '[CC-SSHKEY-02] 私钥内容为空' };
    }
    const info: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(normalized, '');
    if (!info.ok && !info.encrypted) {
      return {
        ok: false,
        key: null,
        fileName: label,
        error: '[CC-SSHKEY-02] 私钥解析失败: ' + (info.error || '未知错误')
      };
    }
    return {
      ok: true,
      key: buildSshKeyFromInspection(label, normalized, info),
      fileName: label,
      error: ''
    };
  }
}

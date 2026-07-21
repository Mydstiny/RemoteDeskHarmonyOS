/**
 * DataCrypto.ets — 敏感数据端到端加密服务
 *
 * 基于 PBKDF2 + AES-256-GCM 的透明加密层.
 * 主密码通过华为密码保险箱跨设备同步, DEK 仅存在于内存.
 *
 * 密文格式: "1:base64(iv):base64(ciphertext+tag)"
 *   - version=1: PBKDF2(100k, SHA256) → AES-256-GCM
 *
 * 安全设计:
 *   - DEK 从不持久化 (仅内存)
 *   - PBKDF2 100,000 迭代 (OWASP 2024)
 *   - AES-256-GCM 认证加密 (防篡改)
 *   - 常量时间验证器比较 (防时序攻击)
 *   - 失败锁定 (5次/30秒)
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { RemoteHost } from '../model/RemoteHost';
import { RdpCredential } from '../model/RdpCredential';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { SshKey } from '../model/SshKey';
import { TotpEntry } from '../model/TotpEntry';

const TAG = 'DataCrypto';
const DOMAIN = 0x0011;

// ============================================================
// CloudStore 接口 (用于类型定义, 避免循环依赖)
// ============================================================

export interface CryptoCloudStore {
  loadAllHostsRaw(): RemoteHost[];
  loadAllRdpCredentialsRaw?(): RdpCredential[];
  loadAllRelaysRaw?(): RustDeskRelayConfig[];
  loadAllSshKeysRaw(): SshKey[];
  loadAllTotpEntriesRaw(): TotpEntry[];
  updateHostRaw(host: RemoteHost): boolean;
  updateRdpCredentialRaw?(credential: RdpCredential): boolean;
  upsertRelayLocalRaw?(relay: RustDeskRelayConfig): boolean;
  syncRelaysToCloud?(): void;
  pushTable?(table: string): void;
  updateSshKeyRaw(key: SshKey): boolean;
  updateTotpEntryRaw(entry: TotpEntry): boolean;
  getStore(): relationalStore.RdbStore | null;
  setCryptoParams(saltB64: string, verifierB64: string): boolean;
  setCryptoStatus?(status: string): boolean;
  clearAllTables?(pushChanges?: boolean): Promise<boolean>;
  clearCryptoParams?(): Promise<boolean>;
  pushTable?(table: string): void;
}

export type DataCryptoStateListener = (ready: boolean, configured: boolean) => void;

// ============================================================
// DataCrypto 单例
// ============================================================

export class DataCrypto {
  private static instance: DataCrypto | null = null;

  // 常量
  readonly PBKDF2_ITERATIONS: number = 100000;
  readonly SALT_LENGTH: number = 32;
  readonly IV_LENGTH: number = 12;
  readonly TAG_LENGTH: number = 16;
  readonly KEY_SIZE: number = 32; // AES-256
  readonly CURRENT_VERSION: number = 1;
  readonly ENCRYPTED_PREFIX: string = '1:';
  readonly VERIFY_CONTEXT: string = 'remotedesktop-verify-v1';
  readonly MAX_ATTEMPTS: number = 5;
  readonly LOCK_DURATION_MS: number = 30000;

  // 状态
  private dek: Uint8Array | null = null; // 内存中的 DEK
  private ready: boolean = false;
  private attemptCount: number = 0;
  private lockUntil: number = 0;

  // CloudStore 引用 (由 init 设置)
  private cloudStore: Object | null = null;
  private stateListeners: Array<DataCryptoStateListener> = [];

  static getInstance(): DataCrypto {
    if (!DataCrypto.instance) {
      DataCrypto.instance = new DataCrypto();
    }
    return DataCrypto.instance;
  }

  private constructor() {}

  // ============================================================
  // 公开 API
  // ============================================================

  /** DEK 是否已就绪 (已解锁) */
  isReady(): boolean {
    return this.ready && this.dek !== null;
  }

  /** 是否已完成初始设置 (检查盐值是否存在) */
  isSetupComplete(): boolean {
    try {
      const salt = this.getCloudPref('crypto_salt');
      return salt.length > 0;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 初始化 — 注入 CloudStore 引用
   * @param cloudStore CloudStore 实例 (需要 getStore/setStore 方法)
   */
  init(cloudStore: Object): void {
    this.cloudStore = cloudStore;
  }

  /** Services use this to discard redacted/decrypted snapshots exactly when the DEK state changes. */
  onStateChange(listener: DataCryptoStateListener): () => void {
    if (this.stateListeners.indexOf(listener) < 0) { this.stateListeners.push(listener); }
    return (): void => {
      const index: number = this.stateListeners.indexOf(listener);
      if (index >= 0) { this.stateListeners.splice(index, 1); }
    };
  }

  /**
   * 设置主密码 (首次使用)
   * 生成随机盐, PBKDF2 派生 DEK, 计算验证器, 存储到 cloudPrefs
   */
  async setMasterPassword(password: string): Promise<void> {
    if (!password || password.length < 8) {
      throw new Error('[DataCrypto] 密码长度不足 (最少 8 位)');
    }

    try {
      // 1. 生成随机盐
      const salt = this.generateRandomSync(this.SALT_LENGTH);

      // 2. PBKDF2 派生 DEK
      const dek = await this.deriveKey(password, salt);

      // 3. HMAC 计算验证器
      const verifier = await this.computeVerifier(dek);

      // 4. 存储盐值和验证器 -> 云端 (通过 insertSync 触发云同步)
      const saltB64 = this.base64Encode(salt);
      const verifierB64 = this.base64Encode(verifier);

      const cryptoStore = this.cloudStore as CryptoCloudStore;
      if (cryptoStore && cryptoStore.setCryptoParams) {
        if (!cryptoStore.setCryptoParams(saltB64, verifierB64)) {
          throw new Error('[DataCrypto] 密码学参数未写入本地数据库');
        }
      }

      // 5. 缓存 DEK
      this.dek = dek;
      this.ready = true;
      this.attemptCount = 0;
      this.notifyStateChange();

      hilog.info(DOMAIN, TAG, '主密码已设置, DEK 已派生');
    } catch (err) {
      const detail: string = DataCrypto.errDetail(err);
      hilog.error(DOMAIN, TAG, "[setMasterPassword] 失败: " + detail);
      throw new Error('设置主密码失败: ' + detail);
    }
  }

  /**
   * 解锁 (每次启动或恢复前台时调用)
   * 从 cloudPrefs 读取盐值和验证器, PBKDF2 派生 DEK 并验证
   * @returns true=解锁成功, false=密码错误
   */
  async unlock(password: string): Promise<boolean> {
    // 检查是否被锁定
    if (this.isLocked()) {
      const remaining = Math.ceil((this.lockUntil - Date.now()) / 1000);
      hilog.warn(DOMAIN, TAG, "已锁定, 剩余 " + remaining.toString() + " 秒");
      return false;
    }

    try {
      // 1. 读取盐值和验证器
      const params = this.getCryptoParams();
      if (!params) {
        hilog.error(DOMAIN, TAG, '未找到加密参数, 请先设置主密码');
        return false;
      }

      // 2. 解码
      const salt = this.base64Decode(params['salt'] as string);
      const storedVerifier = this.base64Decode(params['verifier'] as string);

      // 3. PBKDF2 派生候选 DEK
      const candidateDek = await this.deriveKey(password, salt);

      // 4. 计算验证器
      const candidateVerifier = await this.computeVerifier(candidateDek);

      // 5. 常量时间比较
      if (this.constantTimeEqual(candidateVerifier, storedVerifier)) {
        // 成功
        this.dek = candidateDek;
        this.ready = true;
        this.attemptCount = 0;
        this.notifyStateChange();
        hilog.info(DOMAIN, TAG, 'DEK 解锁成功');
        return true;
      } else {
        // 失败
        this.attemptCount++;
        const remaining = this.MAX_ATTEMPTS - this.attemptCount;
        hilog.warn(DOMAIN, TAG, "密码验证失败, 剩余尝试: " + remaining.toString());
        if (this.attemptCount >= this.MAX_ATTEMPTS) {
          this.lockUntil = Date.now() + this.LOCK_DURATION_MS;
          hilog.error(DOMAIN, TAG, "已锁定 " + (this.LOCK_DURATION_MS / 1000).toString() + " 秒");
        }
        return false;
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, "解锁失败: " + DataCrypto.errDetail(err));
      return false;
    }
  }

  /**
   * 加密明文 → 格式化密文
   * @param plaintext 明文字符串
   * @returns "1:base64(iv):base64(ciphertext+tag)" 格式的密文
   */
  /**
   * 加密明文 → 格式化密文
   * 失败时抛出异常，绝不静默返回明文
   * @throws {Error} 加密失败或 DEK 未就绪
   */
  encrypt(plaintext: string): string {
    if (!this.ready || !this.dek) {
      throw new Error('[DataCrypto] encrypt: DEK 未就绪，请先解锁');
    }
    if (!plaintext || plaintext.length === 0) {
      return plaintext;
    }

    try {
      // 1. 生成随机 IV (12 bytes)
      const iv = this.generateRandomSync(this.IV_LENGTH);

      // 2. 创建 AES-256-GCM 加密器
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      const symKey = this.importDekAsSymKey();

      // 3. GCM 参数
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: new Uint8Array(this.TAG_LENGTH) },
        algName: 'GcmParamsSpec'
      };

      // 4. 初始化 + 加密
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);
      const plainData: cryptoFramework.DataBlob = { data: this.stringToUint8Array(plaintext) };
      const encryptData = cipher.doFinalSync(plainData);

      // 5. GCM doFinalSync 输出已经是 ciphertext + authTag。
      const ctWithTag = new Uint8Array(encryptData.data);

      // 6. 格式化: "1:base64(iv):base64(ct+tag)"
      const result = this.ENCRYPTED_PREFIX + this.base64Encode(iv) + ":" + this.base64Encode(ctWithTag);
      return result;
    } catch (err) {
      const errMsg: string = err instanceof Error ? err.message : DataCrypto.errDetail(err);
      hilog.error(DOMAIN, TAG, "[encrypt] 加密失败: " + errMsg);
      throw new Error("[DataCrypto] encrypt: 加密失败 — " + errMsg);
    }
  }

  /**
   * 解密密文 → 明文
   * 失败时抛出异常，绝不静默返回密文
   * @param wrapped 密文字符串 (或明文 — 兼容旧数据)
   * @throws {Error} 解密失败
   */
  decrypt(wrapped: string): string {
    if (!wrapped || wrapped.length === 0) {
      return wrapped;
    }

    // 兼容旧未加密数据: 非密文格式直接返回
    if (!this.isEncrypted(wrapped)) {
      hilog.info(DOMAIN, TAG, '[decrypt] 旧数据格式, 视为明文');
      return wrapped;
    }

    if (!this.ready || !this.dek) {
      throw new Error('[DataCrypto] decrypt: DEK 未就绪，请先解锁');
    }

    try {
      // 1. 解析格式: "1:base64(iv):base64(ct+tag)"
      const parts = wrapped.substring(2).split(':');
      if (parts.length !== 2) {
        throw new Error("[DataCrypto] decrypt: 密文格式错误 parts=" + parts.length.toString());
      }

      const iv = this.base64Decode(parts[0]);
      let ctWithTag = this.base64Decode(parts[1]);

      if (iv.length !== this.IV_LENGTH) {
        throw new Error("[DataCrypto] decrypt: IV 长度错误 len=" + iv.length.toString() + " exp=" + this.IV_LENGTH.toString());
      }
      if (ctWithTag.length < this.TAG_LENGTH) {
        throw new Error("[DataCrypto] decrypt: 密文太短 len=" + ctWithTag.length.toString() + " min=" + this.TAG_LENGTH.toString());
      }

      // 2. 解密。先按新格式尝试；失败后再兼容早期错误格式:
      // ciphertext+tag 后又追加 16 字节空 tag。
      let decryptData: cryptoFramework.DataBlob;
      try {
        decryptData = this.decryptGcmPayload(iv, ctWithTag);
      } catch (primaryErr) {
        if (ctWithTag.length >= this.TAG_LENGTH * 2 && this.hasTrailingZeroTag(ctWithTag)) {
          decryptData = this.decryptGcmPayload(iv, ctWithTag.subarray(0, ctWithTag.length - this.TAG_LENGTH));
        } else {
          throw new Error(DataCrypto.errDetail(primaryErr));
        }
      }

      return this.uint8ArrayToString(decryptData.data);
    } catch (err) {
      const errMsg: string = err instanceof Error ? err.message : DataCrypto.errDetail(err);
      hilog.error(DOMAIN, TAG, "[decrypt] 解密失败: " + errMsg);
      throw new Error("[DataCrypto] decrypt: 解密失败 (密钥不匹配或数据损坏) — " + errMsg);
    }
  }

  /** 检查字符串是否为加密格式 */
  isEncrypted(data: string): boolean {
    return data.length > 0 && data.startsWith(this.ENCRYPTED_PREFIX);
  }

  /** 清除内存 DEK (切后台时调用) — 保留云端盐值+验证器, 回前台后可解锁恢复 */
  lock(): boolean {
    const changed: boolean = this.ready || this.dek !== null;
    if (this.dek) {
      this.dek.fill(0); // 覆写内存
    }
    this.dek = null;
    this.ready = false;
    if (changed) { this.notifyStateChange(); }
    hilog.info(DOMAIN, TAG, 'DEK 已清除 (lock)');
    return changed;
  }

  /** 清除所有加密状态 (用户主动关闭加密时调用) — 清除盐值+验证器, 数据恢复明文存储 */
  resetSetup(): void {
    this.lock();
    this.attemptCount = 0;
    this.lockUntil = 0;
    // RDB 删除必须由 CloudStore.clearCryptoParams() 完成，避免绕过同步协调器。
    hilog.info(DOMAIN, TAG, '加密内存状态已清除 (resetSetup)');
  }

  /**
   * 关闭加密 (需验证密码)
   * 验证密码并保留 DEK 在内存中, 供调用方执行批量解密。
   * @returns true=验证成功 DEK已就绪, false=密码错误
   */
  async disableEncryption(password: string): Promise<boolean> {
    return await this.unlock(password);
  }

  /**
   * 重置加密 (忘记密码, 无需验证)
   * 设置 crypto_status='reset', 清空所有业务表, 清除加密参数, 零化 DEK
   */
  async resetEncryption(cloud: CryptoCloudStore): Promise<void> {
    hilog.info(DOMAIN, TAG, '开始重置加密...');
    try {
      // 1. 先写状态信令 (其他设备收到后执行本地清理)
      if (!cloud.setCryptoStatus || !cloud.setCryptoStatus('reset')) {
        throw new Error('[DataCrypto] 重置信令未写入本地数据库');
      }

      // 2. 清空三张业务表
      if (!cloud.clearAllTables || !(await cloud.clearAllTables(false))) {
        if (cloud.setCryptoStatus) { cloud.setCryptoStatus('active'); }
        throw new Error('[DataCrypto] 业务数据未完整清空');
      }

      // 3. 清除加密参数 (salt + verifier, crypto_status 保留为 'reset')
      this.lock();
      this.attemptCount = 0;
      this.lockUntil = 0;
      if (!cloud.clearCryptoParams || !(await cloud.clearCryptoParams())) {
        throw new Error('[DataCrypto] 密码学参数未完整清除');
      }

      // 4. 推送 cryptoparams 变更到云端
      if (cloud.pushTable) {
        cloud.pushTable('cryptoparams');
        cloud.pushTable('remotehosts');
        cloud.pushTable('rdpcredentials');
        cloud.pushTable('rustdeskrelays');
        cloud.pushTable('sshkeys');
        cloud.pushTable('totpentries');
      }

      hilog.info(DOMAIN, TAG, '重置加密完成');
    } catch (err) {
      hilog.error(DOMAIN, TAG, "[resetEncryption] 失败: " + DataCrypto.errDetail(err));
      throw new Error('重置加密失败');
    }
  }

  /**
   * 自动迁移 — 加密所有未加密的敏感数据
   * @param cloud CloudStore 实例
   * @returns 迁移的记录数
   */
  // 注意: 迁移操作不是事务性的。如果中途崩溃，部分记录可能已加密。
  // 重新运行 autoMigrate 会跳过已加密的记录 (幂等), 因此不会造成数据损坏。
  async autoMigrate(cloud: CryptoCloudStore): Promise<number> {
    if (!this.ready || !this.dek) {
      hilog.warn(DOMAIN, TAG, 'DEK 未就绪, 跳过迁移');
      return 0;
    }

    let count = 0;
    let hostsChanged: boolean = false;
    let rdpCredentialsChanged: boolean = false;
    let relayChanged: boolean = false;
    let sshKeysChanged: boolean = false;
    let totpEntriesChanged: boolean = false;
    hilog.info(DOMAIN, TAG, '开始自动迁移...');

    try {
      // 1. 迁移 remotehosts 表
      const hosts: RemoteHost[] = cloud.loadAllHostsRaw();
      for (const h of hosts) {
        let changed = false;
        try {
          if (h.password && !this.isEncrypted(h.password)) {
            h.password = this.encrypt(h.password);
            changed = true;
          }
          if (h.sshKeyData && !this.isEncrypted(h.sshKeyData)) {
            h.sshKeyData = this.encrypt(h.sshKeyData);
            changed = true;
          }
          if (h.sshKeyPassphrase && !this.isEncrypted(h.sshKeyPassphrase)) {
            h.sshKeyPassphrase = this.encrypt(h.sshKeyPassphrase);
            changed = true;
          }
          if (changed) {
            if (cloud.updateHostRaw(h)) {
              hostsChanged = true;
              count++;
            }
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, "迁移 host " + h.id + " 失败: " + JSON.stringify(e));
        }
      }

      // 2. 迁移 rdpcredentials 表
      if (cloud.loadAllRdpCredentialsRaw && cloud.updateRdpCredentialRaw) {
        const credentials: RdpCredential[] = cloud.loadAllRdpCredentialsRaw();
        for (const credential of credentials) {
          try {
            if (credential.password && !this.isEncrypted(credential.password)) {
              credential.password = this.encrypt(credential.password);
              if (cloud.updateRdpCredentialRaw(credential)) {
                rdpCredentialsChanged = true;
                count++;
              }
            }
          } catch (e) {
            hilog.warn(DOMAIN, TAG, "迁移 rdpcredential " + credential.id + " 失败: " + DataCrypto.errDetail(e));
          }
        }
      }

      // 3. 迁移 rustdeskrelays 表
      if (cloud.loadAllRelaysRaw && cloud.upsertRelayLocalRaw) {
        const relays: RustDeskRelayConfig[] = cloud.loadAllRelaysRaw();
        for (const relay of relays) {
          let changed: boolean = false;
          try {
            if (relay.apiPassword && !this.isEncrypted(relay.apiPassword)) {
              relay.apiPassword = this.encrypt(relay.apiPassword);
              changed = true;
            }
            if (relay.key && !this.isEncrypted(relay.key)) {
              relay.key = this.encrypt(relay.key);
              changed = true;
            }
            for (let i = 0; i < relay.accounts.length; i++) {
              if (relay.accounts[i].password && !this.isEncrypted(relay.accounts[i].password)) {
                relay.accounts[i].password = this.encrypt(relay.accounts[i].password);
                changed = true;
              }
            }
            if (changed) {
              if (cloud.upsertRelayLocalRaw(relay)) {
                relayChanged = true;
                count++;
              }
            }
          } catch (e) {
            hilog.warn(DOMAIN, TAG, "迁移 rustdeskrelay " + relay.id + " 失败: " + DataCrypto.errDetail(e));
          }
        }
      }

      // 4. 迁移 sshkeys 表
      const keys: SshKey[] = cloud.loadAllSshKeysRaw();
      for (const k of keys) {
        try {
          if (k.privateKey && !this.isEncrypted(k.privateKey)) {
            k.privateKey = this.encrypt(k.privateKey);
            if (cloud.updateSshKeyRaw(k)) {
              sshKeysChanged = true;
              count++;
            }
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, "迁移 sshkey " + k.id + " 失败: " + JSON.stringify(e));
        }
      }

      // 5. 迁移 totpentries 表
      const entries: TotpEntry[] = cloud.loadAllTotpEntriesRaw();
      for (const e of entries) {
        try {
          if (e.secret && !this.isEncrypted(e.secret)) {
            e.secret = this.encrypt(e.secret);
            if (cloud.updateTotpEntryRaw(e)) {
              totpEntriesChanged = true;
              count++;
            }
          }
        } catch (err) {
          hilog.warn(DOMAIN, TAG, "迁移 totp " + e.id + " 失败: " + DataCrypto.errDetail(err));
        }
      }
      if (cloud.pushTable) {
        if (hostsChanged) { cloud.pushTable('remotehosts'); }
        if (rdpCredentialsChanged) { cloud.pushTable('rdpcredentials'); }
        if (relayChanged) { cloud.pushTable('rustdeskrelays'); }
        if (sshKeysChanged) { cloud.pushTable('sshkeys'); }
        if (totpEntriesChanged) { cloud.pushTable('totpentries'); }
      } else if (relayChanged && cloud.syncRelaysToCloud) {
        // 保持旧的最小兼容接口；CloudStore 正常实现始终走上方的统一入口。
        cloud.syncRelaysToCloud();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, "迁移异常: " + DataCrypto.errDetail(err));
    }

    hilog.info(DOMAIN, TAG, "自动迁移完成: " + count.toString() + " 条记录已加密");
    return count;
  }

  // ============================================================
  // 内部方法
  // ============================================================

  /** 是否为锁定状态 */
  private isLocked(): boolean {
    if (this.lockUntil > Date.now()) {
      return true;
    }
    if (this.lockUntil > 0) {
      // 锁定期已过, 重置
      this.attemptCount = 0;
      this.lockUntil = 0;
    }
    return false;
  }

  private notifyStateChange(): void {
    const listeners: Array<DataCryptoStateListener> = this.stateListeners.slice();
    const ready: boolean = this.isReady();
    const configured: boolean = this.isSetupComplete();
    for (let i = 0; i < listeners.length; i++) {
      try { listeners[i](ready, configured); } catch (_e) { /* listeners must not affect cryptography */ }
    }
  }

  /** 获取 CloudStore RDB 实例 */
  private getStore(): relationalStore.RdbStore | null {
    try {
      const cryptoStore = this.cloudStore as CryptoCloudStore;
      if (cryptoStore && cryptoStore.getStore) {
        return cryptoStore.getStore();
      }
    } catch (_e) {
      /* ignore */
    }
    return null;
  }

  /** 获取 cloudPref 值 (通过 SQL) */
  private getCloudPref(key: string): string {
    const store = this.getStore();
    if (store) {
      try {
        const rs = store.querySqlSync("SELECT value FROM cryptoparams WHERE key = ?", [key]);
        let result = '';
        if (rs.goToFirstRow()) {
          result = rs.getString(0);
        }
        rs.close();
        return result;
      } catch (_e) {
        return '';
      }
    }
    return '';
  }

  /** 从 cloudPrefs 读取密码学参数 */
  getCryptoParams(): Record<string, string> | null {
    const salt = this.getCloudPref('crypto_salt');
    const verifier = this.getCloudPref('crypto_verifier');
    if (salt && verifier) {
      const result: Record<string, string> = {};
      result['salt'] = salt;
      result['verifier'] = verifier;
      return result;
    }
    return null;
  }

  /** PBKDF2 派生 AES-256 密钥 */
  private async deriveKey(password: string, salt: Uint8Array): Promise<Uint8Array> {
    try {
      const spec: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2',
        password: password,
        salt: salt,
        iterations: this.PBKDF2_ITERATIONS,
        keySize: this.KEY_SIZE
      };
      const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
      const secret = kdf.generateSecretSync(spec);
      return new Uint8Array(secret.data);
    } catch (err) {
      hilog.error(DOMAIN, TAG, "[deriveKey] PBKDF2失败: " + DataCrypto.errDetail(err));
      throw new Error('PBKDF2 密钥派生失败, 设备可能不支持此加密算法');
    }
  }

  /** HMAC-SHA256 计算验证器 */
  private async computeVerifier(dek: Uint8Array): Promise<Uint8Array> {
    try {
      // 官方文档: createMac 参数是摘要算法名 ('SHA256'), 非复合名 ('HMAC|SHA256')
      const mac = cryptoFramework.createMac('SHA256');
      // createSymKeyGenerator('HMAC|SHA256') 强制要求 key 长度 = 32 字节, 匹配 DEK
      const hmacKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC|SHA256');
      const hmacKey = hmacKeyGenerator.convertKeySync({ data: dek });
      mac.initSync(hmacKey);
      const contextData = this.stringToUint8Array(this.VERIFY_CONTEXT);
      mac.updateSync({ data: contextData });
      const result = mac.doFinalSync();
      return new Uint8Array(result.data);
    } catch (err) {
      hilog.error(DOMAIN, TAG, "[computeVerifier] HMAC失败: " + DataCrypto.errDetail(err));
      throw new Error('HMAC 验证器计算失败, 设备可能不支持此加密算法');
    }
  }

  /** 将 DEK (Uint8Array) 导入为 SymKey 对象 (用于 AES 加解密) */
  private importDekAsSymKey(): cryptoFramework.SymKey {
    return this.rawToSymKey(this.dek!, 'AES256');
  }

  private decryptGcmPayload(iv: Uint8Array, ctWithTag: Uint8Array): cryptoFramework.DataBlob {
    if (ctWithTag.length < this.TAG_LENGTH) {
      throw new Error("[DataCrypto] decrypt: 密文太短 len=" + ctWithTag.length.toString() + " min=" + this.TAG_LENGTH.toString());
    }
    const ctLen = ctWithTag.length - this.TAG_LENGTH;
    const ct = new Uint8Array(ctLen);
    ct.set(ctWithTag.subarray(0, ctLen));
    const tag = new Uint8Array(this.TAG_LENGTH);
    tag.set(ctWithTag.subarray(ctLen));

    const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
    const symKey = this.importDekAsSymKey();
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: tag },
      algName: 'GcmParamsSpec'
    };
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
    return cipher.doFinalSync({ data: ct });
  }

  /** 将原始字节转换为 SymKey */
  private rawToSymKey(keyData: Uint8Array, algName: string): cryptoFramework.SymKey {
    const keyGenerator = cryptoFramework.createSymKeyGenerator(algName);
    const keyBlob: cryptoFramework.DataBlob = { data: keyData };
    const symKey = keyGenerator.convertKeySync(keyBlob);
    return symKey;
  }

  /**
   * 生成密码学安全随机字节
   *
   * 部分设备固件 cryptoFramework.createRandom() 可能返回 401 (硬件RNG不可用),
   * 重试2次后仍失败则抛出明确错误 (不做 Math.random 不安全回退)。
   */
  private generateRandomSync(length: number): Uint8Array {
    let lastErr: string = '';
    for (let retry = 0; retry < 2; retry++) {
      try {
        const rand = cryptoFramework.createRandom();
        const blob = rand.generateRandomSync(length);
        if (blob && blob.data) {
          return new Uint8Array(blob.data);
        }
        lastErr = 'generateRandomSync 返回空数据';
      } catch (err) {
        lastErr = DataCrypto.errDetail(err);
        hilog.warn(DOMAIN, TAG,
          "[generateRandom] 硬件RNG不可用 (retry=" + retry.toString() + "): " + lastErr);
      }
    }
    throw new Error('硬件随机数生成器不可用 (' + lastErr + '), 请确认设备支持加密功能');
  }

  /** 常量时间字节比较 (防时序攻击) */
  private constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) {
      return false;
    }
    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= (a[i] ^ b[i]);
    }
    return result === 0;
  }

  private hasTrailingZeroTag(data: Uint8Array): boolean {
    for (let i = data.length - this.TAG_LENGTH; i < data.length; i++) {
      if (data[i] !== 0) { return false; }
    }
    return true;
  }

  // ============================================================
  // 编码辅助
  // ============================================================

  /** Base64 编码 */
  private base64Encode(data: Uint8Array): string {
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(data);
  }

  /** Base64 解码 */
  private base64Decode(encoded: string): Uint8Array {
    const helper = new util.Base64Helper();
    return helper.decodeSync(encoded);
  }

  /** 字符串 → Uint8Array (UTF-8) */
  private stringToUint8Array(str: string): Uint8Array {
    const encoder = new util.TextEncoder();
    return encoder.encodeInto(str);
  }

  /** Uint8Array → 字符串 (UTF-8) — 使用 buffer API 正确解码多字节字符 */
  private uint8ArrayToString(data: Uint8Array): string {
    return buffer.from(data).toString('utf-8');
  }

  /**
   * 提取错误详情 (ArkTS Error/BusinessError 属性不可枚举, JSON.stringify 返回 {})
   * @returns "code=N message" 或 "message" 或 "未知错误"
   */
  static errDetail(err: Object): string {
    const e = err as Record<string, Object>;
    const code = e['code'];
    const msg = (e['message'] as string) || '';
    let detail = msg.length > 0 ? msg : '未知错误';
    if (code !== undefined && code !== null) {
      detail = 'code=' + code.toString() + ' ' + detail;
    }
    return detail;
  }
}

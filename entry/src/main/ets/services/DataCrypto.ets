/**
 * DataCrypto.ets — 敏感数据端到端加密服务
 *
 * 基于 PBKDF2 + AES-256-GCM 的透明加密层.
 * 主密码不持久化、不上传；可移植 DEK 仅由用户密码派生并存在于内存.
 *
 * 新密文格式: "3:base64(canonical-header):base64(iv):base64(ciphertext+tag)"
 *   - version=3: PBKDF2-SHA256(600k) + 字段/账号 AAD → AES-256-GCM
 *   - version=1/2 仅用于受控兼容迁移
 *
 * 安全设计:
 *   - DEK 从不持久化 (仅内存)
 *   - 新配置 PBKDF2 600,000 迭代；旧配置按持久元数据兼容
 *   - AES-256-GCM 认证加密 (防篡改)
 *   - 常量时间验证器比较 (防时序攻击)
 *   - 失败锁定 (5次/30秒)
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  CryptoEnvelopeKind,
  classifyCryptoEnvelope,
  cryptoEnvelopeIsProtected
} from './CryptoEnvelopePolicy';

const TAG = 'DataCrypto';
const DOMAIN = 0x0011;

// ============================================================
// CloudStore 接口 (用于类型定义, 避免循环依赖)
// ============================================================

export interface CryptoCloudStore {
  readCryptoParam(key: string, lease: AccountSessionLease | null): string;
  beginExclusiveCryptoLifecycle(
    lease: AccountSessionLease | null
  ): Promise<boolean>;
  endExclusiveCryptoLifecycle(
    lease: AccountSessionLease | null
  ): boolean;
  beginCryptoConfiguration(lease: AccountSessionLease | null): string;
  abortCryptoLifecycle(
    transactionId: string,
    lease: AccountSessionLease | null,
    failure: string
  ): void;
  markCryptoUnlocked(lease: AccountSessionLease | null): boolean;
  markCryptoLocked(lease: AccountSessionLease | null): boolean;
  configureCryptoV3(
    saltB64: string,
    verifierB64: string,
    kdfVersion: number,
    kdfIterations: number,
    keyVersion: number,
    verifierVersion: number,
    crypto: DataCrypto,
    transactionId: string,
    lease: AccountSessionLease | null
  ): number;
  migrateAllDataToScopedV3(
    crypto: DataCrypto,
    lease: AccountSessionLease | null
  ): number;
}

export interface VncFieldEnvelopeHeader {
  scope: string;
  table: string;
  recordId: string;
  fieldName: string;
  schemaVersion: number;
  cryptoVersion: number;
  keyVersion: number;
  aadVersion: number;
}

export interface ScopedFieldEnvelopeHeader extends VncFieldEnvelopeHeader {
  resetEpoch: number;
}

export type DataCryptoStateListener = (ready: boolean, configured: boolean) => void;

// ============================================================
// DataCrypto 单例
// ============================================================

export class DataCrypto {
  private static instance: DataCrypto | null = null;

  // 常量
  readonly LEGACY_PBKDF2_ITERATIONS: number = 100000;
  readonly PBKDF2_ITERATIONS: number = 600000;
  readonly KDF_VERSION: number = 2;
  readonly VERIFIER_VERSION: number = 2;
  readonly SALT_LENGTH: number = 32;
  readonly IV_LENGTH: number = 12;
  readonly TAG_LENGTH: number = 16;
  readonly KEY_SIZE: number = 32; // AES-256
  readonly CURRENT_VERSION: number = 1;
  readonly ENCRYPTED_PREFIX: string = '1:';
  readonly VERIFY_CONTEXT: string = 'remotedesktop-verify-v1';
  readonly MAX_ATTEMPTS: number = 5;
  readonly LOCK_DURATION_MS: number = 30000;
  readonly LEGACY_VNC_CRYPTO_VERSION: number = 2;
  readonly LEGACY_VNC_ENVELOPE_VERSION: number = 2;
  readonly LEGACY_VNC_KEY_VERSION: number = 1;
  readonly LEGACY_VNC_AAD_VERSION: number = 1;
  readonly VNC_CRYPTO_VERSION: number = 3;
  readonly VNC_ENVELOPE_VERSION: number = 3;
  readonly VNC_KEY_VERSION: number = 1;
  readonly VNC_AAD_VERSION: number = 2;
  readonly SCOPED_CRYPTO_VERSION: number = 3;
  readonly SCOPED_ENVELOPE_VERSION: number = 3;
  readonly SCOPED_KEY_VERSION: number = 1;
  readonly SCOPED_AAD_VERSION: number = 1;

  // 状态
  private dek: Uint8Array | null = null; // 内存中的 DEK
  private ready: boolean = false;
  private attemptCount: number = 0;
  private lockUntil: number = 0;
  private scopeLease: AccountSessionLease | null = null;
  private cryptoGeneration: number = 0;
  private pendingCryptoTasks: number = 0;

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
  init(cloudStore: Object, lease?: AccountSessionLease): void {
    this.cloudStore = cloudStore;
    if (lease !== undefined) { this.bindScope(lease); }
  }

  bindScope(lease: AccountSessionLease): void {
    if (accountSessionLeaseEquals(this.scopeLease, lease)) { return; }
    this.invalidateCryptoOperations();
    this.scopeLease = cloneAccountSessionLease(lease);
    this.attemptCount = 0;
    this.lockUntil = 0;
  }

  async prepareScopeTransition(timeoutMs: number = 10000): Promise<boolean> {
    this.invalidateCryptoOperations();
    const startedAt: number = Date.now();
    while (this.pendingCryptoTasks > 0 &&
      Date.now() - startedAt < Math.max(1, timeoutMs)) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 20);
      });
    }
    return this.pendingCryptoTasks === 0;
  }

  /** Services use this to discard redacted/decrypted snapshots exactly when the DEK state changes. */
  onStateChange(listener: DataCryptoStateListener): () => void {
    if (this.stateListeners.indexOf(listener) < 0) { this.stateListeners.push(listener); }
    return (): void => {
      const index: number = this.stateListeners.indexOf(listener);
      if (index >= 0) { this.stateListeners.splice(index, 1); }
    };
  }

  /** Monotonic fence for decrypted local caches. A lock or account-scope
   * transition invalidates every generation captured before it. */
  stateGeneration(): number { return this.cryptoGeneration; }

  /**
   * 设置主密码 (首次使用)
   * 生成随机盐, PBKDF2 派生 DEK, 计算验证器, 存储到 cloudPrefs
   */
  async setMasterPassword(password: string): Promise<void> {
    if (!password || password.length < 8) {
      throw new Error('[DataCrypto] 密码长度不足 (最少 8 位)');
    }

    const operationGeneration: number = this.beginCryptoOperation();
    const operationLease: AccountSessionLease | null = this.scopeLease === null
      ? null : cloneAccountSessionLease(this.scopeLease);
    let candidateDek: Uint8Array | null = null;
    let installed: boolean = false;
    let exclusiveLifecycleAcquired: boolean = false;
    let lifecycleTransactionId: string = '';
    const cryptoStore = this.cloudStore as CryptoCloudStore;
    try {
      if (!cryptoStore) {
        throw new Error('[DataCrypto] 数据存储尚未初始化');
      }
      exclusiveLifecycleAcquired =
        await cryptoStore.beginExclusiveCryptoLifecycle(operationLease);
      if (!exclusiveLifecycleAcquired) {
        throw new Error('[DataCrypto] 无法等待云同步进入安全静默状态');
      }
      if (this.isSetupComplete()) {
        throw new Error('[DataCrypto] 加密已经配置，不能覆盖现有密钥');
      }
      lifecycleTransactionId =
        cryptoStore.beginCryptoConfiguration(operationLease);
      if (lifecycleTransactionId === '') {
        throw new Error('[DataCrypto] 加密生命周期不允许开始配置');
      }
      // 1. 生成随机盐
      const salt = this.generateRandomSync(this.SALT_LENGTH);

      // 2. PBKDF2 派生 DEK
      candidateDek = await this.deriveKey(password, salt);
      if (!this.cryptoOperationIsCurrent(operationGeneration, operationLease)) {
        throw new Error('[DataCrypto] 账号作用域已变更');
      }

      // 3. HMAC 计算验证器
      const verifier = await this.computeVerifier(
        candidateDek,
        this.verifierContext(
          this.VERIFIER_VERSION, this.SCOPED_KEY_VERSION));
      if (!this.cryptoOperationIsCurrent(operationGeneration, operationLease)) {
        throw new Error('[DataCrypto] 账号作用域已变更');
      }

      // 4. 存储盐值和验证器 -> 云端 (通过 insertSync 触发云同步)
      const saltB64 = this.base64Encode(salt);
      const verifierB64 = this.base64Encode(verifier);

      // The candidate key is installed only for the duration of the database
      // transaction. A failed transaction removes it again in the catch/finally
      // path, so encrypted rows can never commit without their matching KDF
      // metadata.
      this.dek = candidateDek;
      this.ready = true;
      const migrated: number =
        cryptoStore.configureCryptoV3(
          saltB64,
          verifierB64,
          this.KDF_VERSION,
          this.PBKDF2_ITERATIONS,
          this.SCOPED_KEY_VERSION,
          this.VERIFIER_VERSION,
          this,
          lifecycleTransactionId,
          operationLease
        );
      if (migrated < 0) {
        this.dek = null;
        this.ready = false;
        throw new Error('[DataCrypto] 加密参数与业务数据原子迁移失败');
      }
      if (!this.cryptoOperationIsCurrent(operationGeneration, operationLease)) {
        throw new Error('[DataCrypto] 账号作用域已变更');
      }

      // 5. 缓存 DEK
      this.dek = candidateDek;
      installed = true;
      this.ready = true;
      this.attemptCount = 0;
      this.notifyStateChange();

      hilog.info(DOMAIN, TAG, '主密码已设置, DEK 已派生');
    } catch (err) {
      if (!installed && this.dek === candidateDek) {
        this.dek = null;
        this.ready = false;
      }
      const detail: string = DataCrypto.errDetail(err);
      if (lifecycleTransactionId !== '') {
        cryptoStore.abortCryptoLifecycle(
          lifecycleTransactionId, operationLease, detail);
      }
      hilog.error(DOMAIN, TAG, "[setMasterPassword] 失败: " + detail);
      throw new Error('设置主密码失败: ' + detail);
    } finally {
      if (!installed && candidateDek !== null) { candidateDek.fill(0); }
      if (exclusiveLifecycleAcquired &&
        !cryptoStore.endExclusiveCryptoLifecycle(operationLease)) {
        hilog.error(DOMAIN, TAG,
          '[setMasterPassword] 数据已安全落库，但同步门闩恢复失败并保持关闭');
      }
      this.endCryptoOperation();
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

    const operationGeneration: number = this.beginCryptoOperation();
    const operationLease: AccountSessionLease | null = this.scopeLease === null
      ? null : cloneAccountSessionLease(this.scopeLease);
    let candidateDek: Uint8Array | null = null;
    let installed: boolean = false;
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
      const storedIterations: number =
        Number(params['kdfIterations'] || '');
      const iterations: number =
        Number.isFinite(storedIterations) && storedIterations >= 100000
          ? Math.floor(storedIterations)
          : this.LEGACY_PBKDF2_ITERATIONS;
      candidateDek = await this.deriveKey(password, salt, iterations);
      if (!this.cryptoOperationIsCurrent(operationGeneration, operationLease)) {
        return false;
      }

      // 4. 计算验证器
      const storedVerifierVersion: number =
        Number(params['verifierVersion'] || '');
      const storedKeyVersion: number =
        Number(params['keyVersion'] || '');
      const verifierVersion: number =
        Number.isFinite(storedVerifierVersion) &&
        storedVerifierVersion >= this.VERIFIER_VERSION
          ? Math.floor(storedVerifierVersion) : 1;
      const keyVersion: number =
        Number.isFinite(storedKeyVersion) && storedKeyVersion >= 1
          ? Math.floor(storedKeyVersion) : 1;
      const candidateVerifier = await this.computeVerifier(
        candidateDek,
        this.verifierContext(verifierVersion, keyVersion));
      if (!this.cryptoOperationIsCurrent(operationGeneration, operationLease)) {
        return false;
      }

      // 5. 常量时间比较
      if (this.constantTimeEqual(candidateVerifier, storedVerifier)) {
        // 成功
        const cryptoStore = this.cloudStore as CryptoCloudStore;
        if (!cryptoStore ||
          !cryptoStore.markCryptoUnlocked(operationLease)) {
          hilog.error(DOMAIN, TAG,
            'DEK 验证成功但生命周期状态无法持久化，拒绝解锁');
          return false;
        }
        this.dek = candidateDek;
        installed = true;
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
    } finally {
      if (!installed && candidateDek !== null) { candidateDek.fill(0); }
      this.endCryptoOperation();
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

    const kind: CryptoEnvelopeKind = classifyCryptoEnvelope(wrapped);
    // 兼容旧未加密数据: 非密文格式直接返回
    if (kind === 'plaintext') {
      hilog.info(DOMAIN, TAG, '[decrypt] 旧数据格式, 视为明文');
      return wrapped;
    }
    if (kind !== 'legacy_v1') {
      throw new Error('[DataCrypto] decrypt: 需要字段上下文或密文版本未知');
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
    return cryptoEnvelopeIsProtected(data);
  }

  /**
   * Encrypt an ordinary sensitive field with account, table, record and field
   * identity authenticated as AAD. Ciphertext copied to another field or
   * account cannot be decrypted successfully.
   */
  encryptScoped(scope: string, table: string, recordId: string,
    fieldName: string, plaintext: string, resetEpoch: number,
    schemaVersion: number = 1,
    keyVersion: number = this.SCOPED_KEY_VERSION,
    aadVersion: number = this.SCOPED_AAD_VERSION): string {
    if (!this.ready || !this.dek) {
      throw new Error('[DataCrypto] encryptScoped: DEK 未就绪，请先解锁');
    }
    if (plaintext.length === 0) { return plaintext; }
    this.validateFieldContext(
      scope, table, recordId, fieldName, schemaVersion, keyVersion, aadVersion);
    if (!Number.isFinite(resetEpoch) || resetEpoch < 0) {
      throw new Error('[DataCrypto] encryptScoped: reset epoch 无效');
    }
    try {
      const header: ScopedFieldEnvelopeHeader = {
        scope, table, recordId, fieldName, schemaVersion,
        cryptoVersion: this.SCOPED_CRYPTO_VERSION,
        keyVersion,
        aadVersion,
        resetEpoch: Math.floor(resetEpoch)
      };
      const headerJson: string = this.canonicalScopedHeader(header);
      const aad: Uint8Array =
        this.stringToUint8Array(this.scopedFieldAad(header, headerJson));
      const iv: Uint8Array = this.generateRandomSync(this.IV_LENGTH);
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: aad },
        authTag: { data: new Uint8Array(this.TAG_LENGTH) },
        algName: 'GcmParamsSpec'
      };
      cipher.initSync(
        cryptoFramework.CryptoMode.ENCRYPT_MODE,
        this.importDekAsSymKey(),
        gcmParams
      );
      const encrypted = cipher.doFinalSync({
        data: this.stringToUint8Array(plaintext)
      });
      return this.SCOPED_ENVELOPE_VERSION.toString() + ':' +
        this.base64Encode(this.stringToUint8Array(headerJson)) + ':' +
        this.base64Encode(iv) + ':' +
        this.base64Encode(new Uint8Array(encrypted.data));
    } catch (err) {
      throw new Error('[DataCrypto] encryptScoped: 加密失败 — ' +
        DataCrypto.errDetail(err));
    }
  }

  decryptScoped(scope: string, table: string, recordId: string,
    fieldName: string, envelope: string, resetEpoch: number): string {
    if (!this.ready || !this.dek) {
      throw new Error('[DataCrypto] decryptScoped: DEK 未就绪，请先解锁');
    }
    this.validateFieldContext(scope, table, recordId, fieldName, 1, 1, 1);
    try {
      const parts: string[] = envelope.split(':');
      if (parts.length !== 4 ||
        parts[0] !== this.SCOPED_ENVELOPE_VERSION.toString()) {
        throw new Error('字段密文版本或格式错误');
      }
      const headerJson: string =
        this.uint8ArrayToString(this.base64Decode(parts[1]));
      const header: ScopedFieldEnvelopeHeader =
        this.parseScopedHeader(headerJson);
      if (header.scope !== scope ||
        header.table !== table ||
        header.recordId !== recordId ||
        header.fieldName !== fieldName ||
        header.cryptoVersion !== this.SCOPED_CRYPTO_VERSION ||
        header.resetEpoch !== Math.floor(resetEpoch) ||
        header.keyVersion < 1 ||
        header.aadVersion < 1 ||
        header.schemaVersion < 1) {
        throw new Error('字段密文上下文不匹配');
      }
      const iv: Uint8Array = this.base64Decode(parts[2]);
      const ctWithTag: Uint8Array = this.base64Decode(parts[3]);
      if (iv.length !== this.IV_LENGTH ||
        ctWithTag.length < this.TAG_LENGTH) {
        throw new Error('字段密文长度错误');
      }
      const aad: Uint8Array =
        this.stringToUint8Array(this.scopedFieldAad(header, headerJson));
      const decrypted = this.decryptGcmPayload(iv, ctWithTag, aad);
      return this.uint8ArrayToString(decrypted.data);
    } catch (err) {
      throw new Error(
        '[DataCrypto] decryptScoped: 解密失败 (上下文不匹配或数据损坏) — ' +
        DataCrypto.errDetail(err));
    }
  }

  decryptScopedOrLegacy(scope: string, table: string, recordId: string,
    fieldName: string, value: string, resetEpoch: number): string {
    const kind: CryptoEnvelopeKind = classifyCryptoEnvelope(value);
    if (kind === 'plaintext') { return value; }
    if (kind === 'legacy_v1') { return this.decrypt(value); }
    if (kind === 'scoped_v3') {
      return this.decryptScoped(
        scope, table, recordId, fieldName, value, resetEpoch);
    }
    throw new Error('[DataCrypto] 不支持或损坏的字段密文: ' + kind);
  }

  migrateValueToScopedV3(scope: string, table: string, recordId: string,
    fieldName: string, value: string, resetEpoch: number): string {
    if (value.length === 0) { return value; }
    const kind: CryptoEnvelopeKind = classifyCryptoEnvelope(value);
    if (kind === 'scoped_v3') {
      // Authentication is required even when no rewrite is necessary.
      this.decryptScoped(
        scope, table, recordId, fieldName, value, resetEpoch);
      return value;
    }
    if (kind === 'plaintext') {
      return this.encryptScoped(
        scope, table, recordId, fieldName, value, resetEpoch);
    }
    if (kind === 'legacy_v1') {
      return this.encryptScoped(
        scope, table, recordId, fieldName, this.decrypt(value),
        resetEpoch);
    }
    throw new Error('[DataCrypto] 无法迁移未知或损坏的密文: ' + kind);
  }

  /** New VNC writes use the account/reset-bound v3 envelope. */
  encryptVncFieldV3(scope: string, table: string, recordId: string,
    fieldName: string, plaintext: string, resetEpoch: number,
    schemaVersion: number = 1): string {
    return this.encryptScoped(
      scope, table, recordId, fieldName, plaintext, resetEpoch,
      schemaVersion, this.VNC_KEY_VERSION, this.VNC_AAD_VERSION);
  }

  /** Authenticate and decrypt a VNC v3 envelope in its complete owner context. */
  decryptVncFieldV3(scope: string, table: string, recordId: string,
    fieldName: string, envelope: string, resetEpoch: number): string {
    return this.decryptScoped(
      scope, table, recordId, fieldName, envelope, resetEpoch);
  }

  /**
   * Read-only compatibility path for VNC v2. The fixed legacy scope is never
   * used for a new write; successful reads are rewritten as v3 by CloudStore.
   */
  decryptLegacyVncFieldV2(
    scope: string, table: string, recordId: string,
    fieldName: string, envelope: string
  ): string {
    if (!this.ready || !this.dek) {
      throw new Error(
        '[DataCrypto] decryptLegacyVncFieldV2: DEK 未就绪，请先解锁');
    }
    try {
      const parts: string[] = envelope.split(':');
      if (parts.length !== 4 ||
        parts[0] !== this.LEGACY_VNC_ENVELOPE_VERSION.toString()) {
        throw new Error('VNC 密文版本或格式错误');
      }
      const headerJson: string = this.uint8ArrayToString(this.base64Decode(parts[1]));
      const header: VncFieldEnvelopeHeader = this.parseVncHeader(headerJson);
      if (header.scope !== scope || header.table !== table || header.recordId !== recordId ||
        header.fieldName !== fieldName ||
        header.cryptoVersion !== this.LEGACY_VNC_CRYPTO_VERSION ||
        header.keyVersion !== this.LEGACY_VNC_KEY_VERSION ||
        header.aadVersion !== this.LEGACY_VNC_AAD_VERSION ||
        header.schemaVersion < 1) {
        throw new Error('VNC 密文上下文不匹配');
      }
      const iv: Uint8Array = this.base64Decode(parts[2]);
      const ctWithTag: Uint8Array = this.base64Decode(parts[3]);
      if (iv.length !== this.IV_LENGTH || ctWithTag.length < this.TAG_LENGTH) {
        throw new Error('VNC 密文长度错误');
      }
      const aad: Uint8Array =
        this.stringToUint8Array(this.vncFieldAad(header, headerJson));
      const decrypted = this.decryptGcmPayload(iv, ctWithTag, aad);
      return this.uint8ArrayToString(decrypted.data);
    } catch (err) {
      throw new Error(
        '[DataCrypto] decryptLegacyVncFieldV2: 解密失败 ' +
        '(上下文不匹配或数据损坏) — ' + DataCrypto.errDetail(err));
    }
  }

  /** 清除内存 DEK (切后台时调用) — 保留云端盐值+验证器, 回前台后可解锁恢复 */
  lock(): boolean {
    const operationLease: AccountSessionLease | null =
      this.scopeLease === null
        ? null : cloneAccountSessionLease(this.scopeLease);
    this.cryptoGeneration++;
    const changed: boolean = this.ready || this.dek !== null;
    if (this.dek) {
      this.dek.fill(0); // 覆写内存
    }
    this.dek = null;
    this.ready = false;
    try {
      const cryptoStore = this.cloudStore as CryptoCloudStore;
      if (cryptoStore) { cryptoStore.markCryptoLocked(operationLease); }
    } catch (_e) {
      // The in-memory DEK is already gone. Persistence failure remains
      // fail-closed and will reconcile as locked on the next store open.
    }
    if (changed) { this.notifyStateChange(); }
    hilog.info(DOMAIN, TAG, 'DEK 已清除 (lock)');
    return changed;
  }

  private invalidateCryptoOperations(): void {
    this.lock();
    this.cryptoGeneration++;
  }

  private beginCryptoOperation(): number {
    this.pendingCryptoTasks++;
    return this.cryptoGeneration;
  }

  private endCryptoOperation(): void {
    this.pendingCryptoTasks = Math.max(0, this.pendingCryptoTasks - 1);
  }

  private cryptoOperationIsCurrent(generation: number,
    lease: AccountSessionLease | null): boolean {
    return generation === this.cryptoGeneration &&
      accountSessionLeaseEquals(this.scopeLease, lease);
  }

  /** 清除所有加密状态 (用户主动关闭加密时调用) — 清除盐值+验证器, 数据恢复明文存储 */
  resetSetup(): void {
    this.lock();
    this.attemptCount = 0;
    this.lockUntil = 0;
    // RDB 状态必须由 CloudStore 的原子关闭/重置事务处理。
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

  /** Atomically migrates every account-owned sensitive field to scoped v3. */
  async autoMigrate(cloud: CryptoCloudStore): Promise<number> {
    if (!this.ready || !this.dek) {
      hilog.warn(DOMAIN, TAG, 'DEK 未就绪, 跳过迁移');
      return 0;
    }
    const operationGeneration: number = this.beginCryptoOperation();
    const operationLease: AccountSessionLease | null =
      this.scopeLease === null
        ? null : cloneAccountSessionLease(this.scopeLease);
    let exclusiveLifecycleAcquired: boolean = false;
    try {
      exclusiveLifecycleAcquired =
        await cloud.beginExclusiveCryptoLifecycle(operationLease);
      if (!exclusiveLifecycleAcquired ||
        !this.cryptoOperationIsCurrent(
          operationGeneration, operationLease)) {
        throw new Error('[DataCrypto] 无法等待云同步进入安全静默状态');
      }
      const count: number =
        cloud.migrateAllDataToScopedV3(this, operationLease);
      if (count < 0) {
        throw new Error('[DataCrypto] 原子加密迁移失败，全部改动已回滚');
      }
      hilog.info(DOMAIN, TAG,
        '原子加密迁移完成: ' + count.toString() + ' 条记录已升级');
      return count;
    } finally {
      if (exclusiveLifecycleAcquired &&
        !cloud.endExclusiveCryptoLifecycle(operationLease)) {
        hilog.error(DOMAIN, TAG,
          '[autoMigrate] 数据已安全落库，但同步门闩恢复失败并保持关闭');
      }
      this.endCryptoOperation();
    }
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

  /** 获取 cloudPref 值 (通过 SQL) */
  private getCloudPref(key: string): string {
    try {
      const cryptoStore = this.cloudStore as CryptoCloudStore;
      return cryptoStore
        ? cryptoStore.readCryptoParam(key, this.scopeLease)
        : '';
    } catch (_e) { return ''; }
  }

  /** 从 cloudPrefs 读取密码学参数 */
  getCryptoParams(): Record<string, string> | null {
    const salt = this.getCloudPref('crypto_salt');
    const verifier = this.getCloudPref('crypto_verifier');
    if (salt && verifier) {
      const result: Record<string, string> = {};
      result['salt'] = salt;
      result['verifier'] = verifier;
      result['kdfVersion'] = this.getCloudPref('crypto_kdf_version');
      result['kdfIterations'] =
        this.getCloudPref('crypto_kdf_iterations');
      result['keyVersion'] = this.getCloudPref('crypto_key_version');
      result['verifierVersion'] =
        this.getCloudPref('crypto_verifier_version');
      return result;
    }
    return null;
  }

  /** PBKDF2 派生 AES-256 密钥 */
  private async deriveKey(password: string, salt: Uint8Array,
    iterations: number = this.PBKDF2_ITERATIONS): Promise<Uint8Array> {
    try {
      const spec: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2',
        password: password,
        salt: salt,
        iterations,
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
  private verifierContext(verifierVersion: number, keyVersion: number): string {
    if (verifierVersion <= 1) { return this.VERIFY_CONTEXT; }
    if (this.scopeLease === null ||
      this.scopeLease.ownerScopeId.trim() === '') {
      throw new Error('[DataCrypto] 验证器缺少账户作用域');
    }
    return 'remotedesktop-verify-v2|' +
      this.scopeLease.ownerScopeId +
      '|key=' + keyVersion.toString();
  }

  private async computeVerifier(dek: Uint8Array,
    context: string = this.VERIFY_CONTEXT): Promise<Uint8Array> {
    try {
      // 官方文档: createMac 参数是摘要算法名 ('SHA256'), 非复合名 ('HMAC|SHA256')
      const mac = cryptoFramework.createMac('SHA256');
      // createSymKeyGenerator('HMAC|SHA256') 强制要求 key 长度 = 32 字节, 匹配 DEK
      const hmacKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC|SHA256');
      const hmacKey = hmacKeyGenerator.convertKeySync({ data: dek });
      mac.initSync(hmacKey);
      const contextData = this.stringToUint8Array(context);
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

  private decryptGcmPayload(iv: Uint8Array, ctWithTag: Uint8Array,
    aad: Uint8Array = new Uint8Array(0)): cryptoFramework.DataBlob {
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
      aad: { data: aad },
      authTag: { data: tag },
      algName: 'GcmParamsSpec'
    };
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
    return cipher.doFinalSync({ data: ct });
  }

  private canonicalVncHeader(header: VncFieldEnvelopeHeader): string {
    return '{"aadVersion":' + header.aadVersion.toString() +
      ',"cryptoVersion":' + header.cryptoVersion.toString() +
      ',"fieldName":' + JSON.stringify(header.fieldName) +
      ',"keyVersion":' + header.keyVersion.toString() +
      ',"recordId":' + JSON.stringify(header.recordId) +
      ',"schemaVersion":' + header.schemaVersion.toString() +
      ',"scope":' + JSON.stringify(header.scope) +
      ',"table":' + JSON.stringify(header.table) + '}';
  }

  private parseVncHeader(value: string): VncFieldEnvelopeHeader {
    const parsed: Object = JSON.parse(value) as Object;
    const source: Record<string, Object> = parsed as Record<string, Object>;
    const scope: string = source['scope'] as string;
    const table: string = source['table'] as string;
    const recordId: string = source['recordId'] as string;
    const fieldName: string = source['fieldName'] as string;
    const schemaVersion: number = source['schemaVersion'] as number;
    const cryptoVersion: number = source['cryptoVersion'] as number;
    const keyVersion: number = source['keyVersion'] as number;
    const aadVersion: number = source['aadVersion'] as number;
    if (typeof scope !== 'string' || typeof table !== 'string' || typeof recordId !== 'string' ||
      typeof fieldName !== 'string' || typeof schemaVersion !== 'number' ||
      typeof cryptoVersion !== 'number' || typeof keyVersion !== 'number' || typeof aadVersion !== 'number') {
      throw new Error('VNC 密文头字段错误');
    }
    const header: VncFieldEnvelopeHeader = {
      scope, table, recordId, fieldName, schemaVersion, cryptoVersion, keyVersion, aadVersion
    };
    if (this.canonicalVncHeader(header) !== value) {
      throw new Error('VNC 密文头不是 canonical JSON');
    }
    return header;
  }

  private canonicalScopedHeader(
    header: ScopedFieldEnvelopeHeader
  ): string {
    return '{"aadVersion":' + header.aadVersion.toString() +
      ',"cryptoVersion":' + header.cryptoVersion.toString() +
      ',"fieldName":' + JSON.stringify(header.fieldName) +
      ',"keyVersion":' + header.keyVersion.toString() +
      ',"recordId":' + JSON.stringify(header.recordId) +
      ',"resetEpoch":' + header.resetEpoch.toString() +
      ',"schemaVersion":' + header.schemaVersion.toString() +
      ',"scope":' + JSON.stringify(header.scope) +
      ',"table":' + JSON.stringify(header.table) + '}';
  }

  private parseScopedHeader(value: string): ScopedFieldEnvelopeHeader {
    const parsed: Object = JSON.parse(value) as Object;
    const source: Record<string, Object> =
      parsed as Record<string, Object>;
    const header: ScopedFieldEnvelopeHeader = {
      scope: source['scope'] as string,
      table: source['table'] as string,
      recordId: source['recordId'] as string,
      fieldName: source['fieldName'] as string,
      schemaVersion: source['schemaVersion'] as number,
      cryptoVersion: source['cryptoVersion'] as number,
      keyVersion: source['keyVersion'] as number,
      aadVersion: source['aadVersion'] as number,
      resetEpoch: source['resetEpoch'] as number
    };
    if (typeof header.scope !== 'string' ||
      typeof header.table !== 'string' ||
      typeof header.recordId !== 'string' ||
      typeof header.fieldName !== 'string' ||
      typeof header.schemaVersion !== 'number' ||
      typeof header.cryptoVersion !== 'number' ||
      typeof header.keyVersion !== 'number' ||
      typeof header.aadVersion !== 'number' ||
      typeof header.resetEpoch !== 'number' ||
      !Number.isFinite(header.resetEpoch) ||
      header.resetEpoch < 0 ||
      Math.floor(header.resetEpoch) !== header.resetEpoch ||
      this.canonicalScopedHeader(header) !== value) {
      throw new Error('字段密文头错误或不是 canonical JSON');
    }
    return header;
  }

  private validateFieldContext(scope: string, table: string, recordId: string,
    fieldName: string, schemaVersion: number, keyVersion: number,
    aadVersion: number): void {
    if (scope.trim() === '' ||
      table.trim() === '' ||
      recordId.trim() === '' ||
      fieldName.trim() === '') {
      throw new Error('[DataCrypto] 字段加密上下文不能为空');
    }
    if (schemaVersion < 1 || keyVersion < 1 || aadVersion < 1) {
      throw new Error('[DataCrypto] 字段加密版本无效');
    }
  }

  private vncFieldAad(
    header: VncFieldEnvelopeHeader, headerJson: string
  ): string {
    return header.scope + '|' + header.table + '|' + header.recordId + '|' + header.fieldName + '|' +
      header.schemaVersion.toString() + '|' + headerJson;
  }

  private scopedFieldAad(
    header: ScopedFieldEnvelopeHeader, headerJson: string
  ): string {
    return 'RemoteDeskHarmonyOS|crypto-field-v3|' +
      header.scope + '|' + header.table + '|' +
      header.recordId + '|' + header.fieldName + '|' +
      header.schemaVersion.toString() + '|' +
      header.resetEpoch.toString() + '|' + headerJson;
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

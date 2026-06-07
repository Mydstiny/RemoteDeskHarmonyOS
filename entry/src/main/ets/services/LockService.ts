import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';

export enum LockType {
  NONE = 'none',
  BIOMETRIC = 'biometric',
  PIN = 'pin',
  PASSWORD = 'password'
}

export interface HostCredential {
  hostId: string;
  lockType: LockType;
  credentialHash: string;
}

export class LockService {
  private static instance: LockService;
  private lockedHosts: Map<string, HostCredential> = new Map();

  static getInstance(): LockService {
    if (!this.instance) {
      this.instance = new LockService();
    }
    return this.instance;
  }

  async lockWithBiometric(hostId: string): Promise<boolean> {
    try {
      const authInstance = userAuth.getAuthInstance({
        challenge: new Uint8Array(32),
        authType: [userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.FACE]
      });
      const result = await new Promise<userAuth.UserAuthResult>((resolve, reject) => {
        authInstance.on('result', {
          callback: (res: userAuth.UserAuthResult) => resolve(res)
        });
        authInstance.start();
      });
      if (result.result === userAuth.UserAuthResultCode.SUCCESS) {
        this.lockedHosts.set(hostId, {
          hostId,
          lockType: LockType.BIOMETRIC,
          credentialHash: 'biometric:' + hostId
        });
        console.info('LockService biometric lock enabled for host: ' + hostId);
        return true;
      }
      return false;
    } catch (err) {
      console.error('LockService biometric lock failed: ' + err);
      return false;
    }
  }

  async setPinLock(hostId: string, pin: string): Promise<boolean> {
    try {
      const hash = await this.hashCredential(pin);
      this.lockedHosts.set(hostId, {
        hostId,
        lockType: LockType.PIN,
        credentialHash: hash
      });
      console.info('LockService PIN lock enabled for host: ' + hostId);
      return true;
    } catch (err) {
      console.error('LockService PIN lock failed: ' + err);
      return false;
    }
  }

  async setPasswordLock(hostId: string, password: string): Promise<boolean> {
    try {
      const hash = await this.hashCredential(password);
      this.lockedHosts.set(hostId, {
        hostId,
        lockType: LockType.PASSWORD,
        credentialHash: hash
      });
      console.info('LockService password lock enabled for host: ' + hostId);
      return true;
    } catch (err) {
      console.error('LockService password lock failed: ' + err);
      return false;
    }
  }

  async verifyLock(hostId: string): Promise<boolean> {
    const cred = this.lockedHosts.get(hostId);
    if (!cred || cred.lockType === LockType.NONE) {
      return true;
    }
    if (cred.lockType === LockType.BIOMETRIC) {
      return this.verifyBiometric();
    }
    return false;
  }

  async verifyBiometric(): Promise<boolean> {
    try {
      const authInstance = userAuth.getAuthInstance({
        challenge: new Uint8Array(32),
        authType: [userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.FACE]
      });
      const result = await new Promise<userAuth.UserAuthResult>((resolve, reject) => {
        authInstance.on('result', {
          callback: (res: userAuth.UserAuthResult) => resolve(res)
        });
        authInstance.start();
      });
      return result.result === userAuth.UserAuthResultCode.SUCCESS;
    } catch (err) {
      console.error('Biometric verification failed: ' + err);
      return false;
    }
  }

  async verifyPin(hostId: string, input: string): Promise<boolean> {
    const cred = this.lockedHosts.get(hostId);
    if (!cred) return false;
    const hash = await this.hashCredential(input);
    return hash === cred.credentialHash;
  }

  async unlockHost(hostId: string): Promise<void> {
    this.lockedHosts.delete(hostId);
    console.info('LockService unlocked host: ' + hostId);
  }

  async removeLock(hostId: string): Promise<void> {
    this.lockedHosts.delete(hostId);
    console.info('LockService removed lock for host: ' + hostId);
  }

  getLockType(hostId: string): LockType {
    return this.lockedHosts.get(hostId)?.lockType ?? LockType.NONE;
  }

  isHostLocked(hostId: string): boolean {
    return this.lockedHosts.has(hostId);
  }

  showPinDialog(hostLabel: string, lockType: LockType): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        promptAction.showDialog({
          title: '验证 - ' + hostLabel,
          message: lockType === LockType.PIN ? '请输入PIN码' : '请输入密码',
          buttons: [
            { text: '取消', color: '#FF6B6B' },
            { text: '确定', color: '#6677FF' }
          ]
        }).then((result) => {
          if (result.index === 1) {
            resolve('');
          } else {
            reject(new Error('User cancelled'));
          }
        });
      } catch (err) {
        reject(err);
      }
    });
  }

  private async hashCredential(input: string): Promise<string> {
    const encoder = new util.TextEncoder();
    const data = encoder.encodeInto(input);
    const digest = await crypto.subtle.digest('SHA-256', data);
    const hexArray: string[] = [];
    digest.forEach((b: number) => {
      hexArray.push(b.toString(16).padStart(2, '0'));
    });
    return hexArray.join('');
  }
}

import { BusinessError } from '@kit.BasicServicesKit';

interface NativeAuthModule {
  lockHost(hostId: string, credentialType: number, credentialData: string): number;
  verifyLock(hostId: string, credentialType: number, credentialData: string): number;
  unlockHost(hostId: string): number;
  removeLock(hostId: string): number;
  isHostLocked(hostId: string): boolean;
  getLockType(hostId: string): number;
}

const nativeAuth: NativeAuthModule | null = (() => {
  try {
    const native = requireNapi('librdpnapi') as unknown as NativeAuthModule;
    console.info('NativeAuth native module loaded');
    return native;
  } catch (err) {
    console.error('NativeAuth failed to load librdpnapi: ' + err);
    return null;
  }
})();

export enum NativeCredentialType {
  NONE = 0,
  BIOMETRIC = 1,
  PIN = 2,
  PASSWORD = 3
}

export class NativeAuth {
  private static instance: NativeAuth;

  static getInstance(): NativeAuth {
    if (!this.instance) {
      this.instance = new NativeAuth();
    }
    return this.instance;
  }

  lockHost(hostId: string, credentialType: NativeCredentialType, credentialData: string): boolean {
    if (!nativeAuth) {
      console.warn('NativeAuth native not available, using stub');
      return true;
    }
    try {
      const result = nativeAuth.lockHost(hostId, credentialType, credentialData);
      console.info('NativeAuth lockHost result: ' + result + ' for ' + hostId);
      return result === 0;
    } catch (err) {
      console.error('NativeAuth lockHost failed: ' + err);
      return false;
    }
  }

  verifyLock(hostId: string, credentialType: NativeCredentialType, credentialData: string): boolean {
    if (!nativeAuth) {
      console.warn('NativeAuth native not available, using stub');
      return true;
    }
    try {
      const result = nativeAuth.verifyLock(hostId, credentialType, credentialData);
      console.info('NativeAuth verifyLock result: ' + result + ' for ' + hostId);
      return result === 0;
    } catch (err) {
      console.error('NativeAuth verifyLock failed: ' + err);
      return false;
    }
  }

  unlockHost(hostId: string): boolean {
    if (!nativeAuth) {
      console.warn('NativeAuth native not available, using stub');
      return true;
    }
    try {
      const result = nativeAuth.unlockHost(hostId);
      console.info('NativeAuth unlockHost for ' + hostId);
      return result === 0;
    } catch (err) {
      console.error('NativeAuth unlockHost failed: ' + err);
      return false;
    }
  }

  removeLock(hostId: string): boolean {
    if (!nativeAuth) {
      return true;
    }
    try {
      const result = nativeAuth.removeLock(hostId);
      return result === 0;
    } catch (err) {
      console.error('NativeAuth removeLock failed: ' + err);
      return false;
    }
  }

  isHostLocked(hostId: string): boolean {
    if (!nativeAuth) return false;
    try {
      return nativeAuth.isHostLocked(hostId);
    } catch (err) {
      console.error('NativeAuth isHostLocked failed: ' + err);
      return false;
    }
  }

  getLockType(hostId: string): NativeCredentialType {
    if (!nativeAuth) return NativeCredentialType.NONE;
    try {
      return nativeAuth.getLockType(hostId) as NativeCredentialType;
    } catch (err) {
      console.error('NativeAuth getLockType failed: ' + err);
      return NativeCredentialType.NONE;
    }
  }

  isNativeAvailable(): boolean {
    return nativeAuth !== null;
  }
}

import { describe, it, expect } from '@ohos/hypium';
import {
  SshPreflightService,
  SshPreflightTokenData
} from '../main/ets/services/SshPreflightService';

function tokenData(): SshPreflightTokenData {
  return {
    hostId: 'host-v6',
    expectedHostKeyRawBase64: 'AAAATARGET',
    expectedHostKeyFingerprintSha256: 'SHA256:target',
    targetRouteIdentity: 'route-v6',
    expectedJumpHostKeyRawBase64: 'AAAAJUMP',
    expectedJumpHostKeyFingerprintSha256: 'SHA256:jump',
    privateKeyPassphrase: 'target-passphrase',
    proxyPrivateKeyPassphrase: 'proxy-passphrase',
    routeSecretsRouteIdentity: 'route-v6',
    proxyPassword: 'proxy-password',
    jumpHandoffs: [{
      password: 'hop-password',
      privateKeyPem: '',
      privateKeyPassphrase: '',
      keyboardInteractiveResponses: ['hop-response']
    }]
  };
}

export default function sshPreflightServiceTest(): void {
  describe('SshPreflightService', (): void => {
    it('clones_route_bound_secrets_and_consumes_them_once', 0, (): void => {
      const service: SshPreflightService = SshPreflightService.getInstance();
      service.clearAll();
      const source: SshPreflightTokenData = tokenData();
      const tokenId: string = service.createToken(source);
      source.proxyPassword = 'mutated';
      if (source.jumpHandoffs !== undefined) {
        source.jumpHandoffs[0].password = 'mutated';
        source.jumpHandoffs[0].keyboardInteractiveResponses = ['mutated'];
      }

      const consumed: SshPreflightTokenData | null = service.consume(tokenId);
      expect(consumed === null).assertFalse();
      if (consumed !== null) {
        expect(consumed.routeSecretsRouteIdentity).assertEqual('route-v6');
        expect(consumed.proxyPassword).assertEqual('proxy-password');
        expect(consumed.jumpHandoffs?.[0].password).assertEqual('hop-password');
        expect(consumed.jumpHandoffs?.[0].keyboardInteractiveResponses?.[0]).assertEqual('hop-response');
      }
      expect(service.consume(tokenId)).assertNull();
    });

    it('clears_unconsumed_sensitive_handoffs', 0, (): void => {
      const service: SshPreflightService = SshPreflightService.getInstance();
      service.clearAll();
      const tokenId: string = service.createToken(tokenData());
      service.clearAll();
      expect(service.consume(tokenId)).assertNull();
    });
  });
}

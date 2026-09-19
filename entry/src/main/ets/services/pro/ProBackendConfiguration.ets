import { DEBUG } from 'BuildProfile';
import { util } from '@kit.ArkTS';
import { ProEnvironment } from './ProAccessPolicy';
import { ProTrustConfiguration } from './ProSignedEntitlement';

export interface ProBackendConfiguration {
  trust: ProTrustConfiguration;
  functionName: string;
  functionVersion: string;
}

export function proBackendConfiguration(environment: ProEnvironment): ProBackendConfiguration | null {
  if (DEBUG && environment === 'sandbox') {
    // Populated only from the reviewed sandbox deployment. These are public
    // function identity and a verification key; no server credential belongs in HAP.
    const functionName: string = 'remotedesk-pro-sandbox-api';
    const publicKey: string = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwFkNqYOl4nwEVlV2h0ZLa1oyZ1SHh6Z+1kez8iYjisXySfWmm5u58HstAoUtQOVpIS1Tz9RDADEfjQ/2q8jcP7+bApAWm6rttgLpQsCAcV0kA8BK8nJimteepYsN09USKKlyCMS9JiPqbWE1p7yE176GLH4UeIuoqWEuW/RoHAEgVgGTQKyBRWVpou9zUXLj7kRz9vCYWcJvFPwvxOxFPBRmujN+gnPE3tJwakZASiSkMmtcaKuwe0dxteZQQjcxPLui1h+jwtbs8gheTISoP6BDoIXcbH1BM2eM+2mM4bCW81UIxfg3M4xVo6M98y+tw88Guc43EyS4WFH8yh6K9wIDAQAB';
    if (functionName.length > 0 && publicKey.length > 0) {
      return { functionName, functionVersion: '$latest', trust: { applicationId: '6917607610255320307', issuer: 'remotedesk-pro-sandbox',
        productId: 'RemoteDesktop_Pro_Test', environment: 'sandbox', keyId: 'sandbox-rs256-v1',
        publicKeyDer: new util.Base64Helper().decodeSync(publicKey) } };
    }
  }
  return null;
}

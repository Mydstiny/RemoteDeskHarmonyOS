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
    const functionName: string = '';
    const publicKey: string = '';
    if (functionName.length > 0 && publicKey.length > 0) {
      return { functionName, functionVersion: '$latest', trust: { applicationId: '', issuer: 'remotedesk-pro-sandbox',
        productId: 'RemoteDesktop_Pro_Test', environment: 'sandbox', keyId: 'sandbox-rs256-v1',
        publicKeyDer: new util.Base64Helper().decodeSync(publicKey) } };
    }
  }
  return null;
}

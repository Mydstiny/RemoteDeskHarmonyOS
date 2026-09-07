import { DEBUG } from 'BuildProfile';
import { util } from '@kit.ArkTS';
import { ProEnvironment } from './ProAccessPolicy';
import { ProTrustConfiguration } from './ProSignedEntitlement';

export interface ProBackendConfiguration {
  trust: ProTrustConfiguration;
  intentsUrl: string;
  reconcileUrl: string;
}

export function proBackendConfiguration(environment: ProEnvironment): ProBackendConfiguration | null {
  if (DEBUG && environment === 'sandbox') {
    // Populated only from the reviewed sandbox deployment. These are public
    // endpoints and a verification key; no server credential belongs in HAP.
    const intentsUrl: string = '';
    const reconcileUrl: string = '';
    const publicKey: string = '';
    if (intentsUrl.length > 0 && reconcileUrl.length > 0 && publicKey.length > 0) {
      return { intentsUrl, reconcileUrl, trust: { applicationId: '', issuer: 'remotedesk-pro-sandbox',
        productId: 'RemoteDesktop_Pro_Test', environment: 'sandbox', keyId: 'sandbox-rs256-v1',
        publicKeyDer: new util.Base64Helper().decodeSync(publicKey) } };
    }
  }
  return null;
}

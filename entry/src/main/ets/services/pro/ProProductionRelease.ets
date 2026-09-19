import { util } from '@kit.ArkTS';
import { ProBackendConfiguration } from './ProBackendConfiguration';

export interface ProProductionRelease {
  enabled: boolean;
  functionName: string;
  functionVersion: string;
  applicationId: string;
  productId: string;
  issuer: string;
  keyId: string;
  publicKeyBase64: string;
}
// Populate reviewed production identities only after merchant, product and device acceptance.
// Sandbox identities, credentials and runtime overrides must never enable real checkout.
const RELEASE: ProProductionRelease = {
  enabled: false, functionName: '', functionVersion: '', applicationId: '', productId: '',
  issuer: '', keyId: '', publicKeyBase64: ''
};
export function productionProBackendConfiguration(release: ProProductionRelease = RELEASE): ProBackendConfiguration | null {
  if (!release.enabled || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(release.functionName) ||
    !/^[1-9][0-9]{0,7}$/.test(release.functionVersion) || !/^[0-9]{6,32}$/.test(release.applicationId) ||
    !/^[A-Za-z0-9_.-]{1,128}$/.test(release.productId) ||
    !/^[A-Za-z0-9_.-]{1,100}$/.test(release.issuer) || !/^[A-Za-z0-9_.-]{1,100}$/.test(release.keyId) ||
    /sandbox/i.test(release.functionName + ' ' + release.issuer + ' ' + release.keyId) ||
    release.productId === 'RemoteDesktop_Pro_Test' ||
    !/^[A-Za-z0-9+/]{380,800}={0,2}$/.test(release.publicKeyBase64)) { return null; }
  try {
    const publicKeyDer = new util.Base64Helper().decodeSync(release.publicKeyBase64);
    if (publicKeyDer.length < 256 || publicKeyDer.length > 600 || publicKeyDer[0] !== 0x30) { return null; }
    return { functionName: release.functionName, functionVersion: release.functionVersion,
      trust: { applicationId: release.applicationId, productId: release.productId, issuer: release.issuer,
        keyId: release.keyId, environment: 'production', publicKeyDer } };
  } catch (_error) { return null; }
}

import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { VncHostView } from '../main/ets/services/VncHostService';
import {
  isVncHostProjection, projectVncHost, vncHostRecordIdFromUiId, vncHostUiId
} from '../main/ets/services/VncHostListProjectionPolicy';

function view(): VncHostView {
  return {
    id: 'host-record-1', userId: 'user-1', label: 'Mac VNC', host: '192.0.2.20', port: 5900,
    username: '', gatewayId: '', transport: 'direct_tcp', repeaterMode: 'mode12',
    rememberPassword: false, viewOnly: true, displayOverrideEnabled: true,
    scalingMode: 'fit', clipboardEnabled: false,
    securityPolicy: 'secure_only', tls: true, locked: true, lockType: 1,
    createdAt: 10, updatedAt: 20, syncVersion: 2, passwordConfigured: false
  };
}

export default function vncHostListProjectionPolicyTest(): void {
  describe('VncHostListProjectionPolicy', (): void => {
    it('uses a collision-resistant UI id without changing the VNC record id', 0, (): void => {
      expect(vncHostUiId('host-record-1')).assertEqual('vnc:host-record-1');
      expect(vncHostRecordIdFromUiId('vnc:host-record-1')).assertEqual('host-record-1');
      expect(vncHostRecordIdFromUiId('host-record-1')).assertEqual('');
    });

    it('projects lock state and endpoint for the existing host-card surface', 0, (): void => {
      const projected: RemoteHost = projectVncHost(view());
      expect(projected.id).assertEqual('vnc:host-record-1');
      expect(projected.protocol).assertEqual('vnc');
      expect(projected.sourceType).assertEqual('vnc');
      expect(projected.locked).assertTrue();
      expect(projected.host).assertEqual('192.0.2.20');
      expect(isVncHostProjection(projected)).assertTrue();
    });
  });
}

/**
 * Component.test.ets — UI component tests (hypium, on-device)
 *
 * Test scope: component rendering, interaction state
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../../../main/ets/model/RemoteHost';

export default function componentTest() {
  describe('RemoteHost_Data_Validation', () => {
    it('valid_host_should_pass_validation', 0, () => {
      const host = new RemoteHost();
      host.label = 'OfficePC';
      host.protocol = 'rdp';
      host.host = '192.168.1.100';
      host.port = 3389;
      host.username = 'admin';

      expect(host.isValid()).assertTrue();
    });

    it('empty_label_should_fail_validation', 0, () => {
      const host = new RemoteHost();
      host.host = '192.168.1.100';
      host.username = 'admin';

      const errors = host.getValidationErrors();
      expect(errors.length > 0).assertTrue();
    });

    it('rustdesk_without_relay_or_direct_host_should_fail_validation', 0, () => {
      const host = new RemoteHost();
      host.label = 'Desk';
      host.protocol = 'rustdesk';
      host.customHostname = '123456789';
      host.password = 'secret';

      const errors = host.getValidationErrors();
      expect(errors.includes('RustDesk 需要选择中继配置或填写直连地址')).assertTrue();
      expect(host.isValid()).assertFalse();
    });

    it('rustdesk_direct_host_should_pass_validation', 0, () => {
      const host = new RemoteHost();
      host.label = 'Desk';
      host.protocol = 'rustdesk';
      host.customHostname = '123456789';
      host.password = 'secret';
      host.rustdeskDirectEnabled = true;
      host.rustdeskDirectHost = '192.168.1.20';
      host.host = '192.168.1.20';
      host.port = 21116;

      expect(host.getValidationErrors().length).assertEqual(0);
      expect(host.isValid()).assertTrue();
    });
  });

  describe('Protocol_Default_Ports', () => {
    it('RDP_default_3389', 0, () => {
      const host = new RemoteHost();
      host.protocol = 'rdp';
      host.port = RemoteHost.getDefaultPort('rdp');
      expect(host.port).assertEqual(3389);
    });

    it('RustDesk_default_21116', 0, () => {
      const host = new RemoteHost();
      host.protocol = 'rustdesk';
      host.port = RemoteHost.getDefaultPort('rustdesk');
      expect(host.port).assertEqual(21116);
    });
  });

  describe('Host_ID_Generation', () => {
    it('should_generate_unique_IDs', 0, () => {
      const id1 = RemoteHost.generateId();
      const id2 = RemoteHost.generateId();
      expect(id1 === id2).assertFalse();
    });

    it('ID_should_start_with_host_prefix', 0, () => {
      const id = RemoteHost.generateId();
      expect(id.startsWith('host_')).assertTrue();
    });
  });

  describe('Host_Lock_State', () => {
    it('default_should_not_be_locked', 0, () => {
      const host = new RemoteHost();
      expect(host.locked).assertFalse();
    });

    it('should_set_locked_state', 0, () => {
      const host = new RemoteHost();
      host.locked = true;
      host.lockType = 3;
      expect(host.locked).assertTrue();
      expect(host.lockType).assertEqual(3);
    });
  });
}

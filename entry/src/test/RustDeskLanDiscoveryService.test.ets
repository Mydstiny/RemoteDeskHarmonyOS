/** RustDeskLanDiscoveryService.test.ets — RustDesk LAN protobuf 回归测试 */

import { describe, it, expect } from '@ohos/hypium';
import {
  encodeRustDeskLanPeerDiscovery,
  encodeRustDeskLanPing,
  parseRustDeskLanPeerDiscovery,
  RustDeskLanPeerDiscovery
} from '../main/ets/services/RustDeskLanDiscoveryService';

export default function rustDeskLanDiscoveryServiceTest() {
  describe('RustDeskLanDiscoveryService_Encode', () => {
    it('ping_should_use_rendezvous_peer_discovery_field', 0, () => {
      const bytes: Uint8Array = new Uint8Array(encodeRustDeskLanPing());
      expect(bytes.length).assertEqual(9);
      // field 22 + length-delimited wire type => varint 0xB2 0x01
      expect(bytes[0]).assertEqual(0xB2);
      expect(bytes[1]).assertEqual(0x01);
      // inner PeerDiscovery.cmd = "ping": field 1, length 4, payload ping
      expect(bytes[3]).assertEqual(0x0A);
      expect(bytes[4]).assertEqual(0x04);
    });
  });

  describe('RustDeskLanDiscoveryService_Decode', () => {
    it('pong_should_decode_peer_identity_and_display_fields', 0, () => {
      const peer: RustDeskLanPeerDiscovery = {
        cmd: 'pong',
        mac: '00:11:22:33:44:55',
        id: '123456789',
        username: 'operator',
        hostname: 'office-pc',
        platform: 'Windows',
        misc: ''
      };
      const parsed: RustDeskLanPeerDiscovery | null =
        parseRustDeskLanPeerDiscovery(encodeRustDeskLanPeerDiscovery(peer));
      if (parsed === null) {
        expect(false).assertTrue();
        return;
      }
      expect(parsed.cmd).assertEqual('pong');
      expect(parsed.id).assertEqual('123456789');
      expect(parsed.hostname).assertEqual('office-pc');
      expect(parsed.platform).assertEqual('Windows');
      expect(parsed.mac).assertEqual('00:11:22:33:44:55');
    });
  });
}

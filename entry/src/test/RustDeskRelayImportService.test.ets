import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayImportService, RustDeskRelayImportResult } from '../main/ets/services/RustDeskRelayImportService';
import { resolveRustDeskRelayKey } from '../main/ets/services/RustDeskRelayKeyPolicy';

const OFFICIAL_REVERSED_BASE64 =
  '9JSeltWL0NXZ0JiOikXZrJCLi02bj5SZsBXbhhXZukGch9yL6MHc0RHaiojIpBXYiwiI3ETMxIjOt92YuUGbw1WY4VmL5FGblJnI6ISehxWZyJCLiYTMxEjM602bj5SZsBXbhhXZuQWaiojI0N3boJye';

export default function rustDeskRelayImportServiceTest(): void {
  describe('RustDeskRelayImportService', (): void => {
    const service = new RustDeskRelayImportService();

    it('parses_official_reversed_base64url_config', 0, (): void => {
      const result: RustDeskRelayImportResult = service.parse('official', OFFICIAL_REVERSED_BASE64);
      expect(result.ok).assertTrue();
      expect(result.idServer).assertEqual('id.example.com');
      expect(result.idServerPort).assertEqual(21116);
      expect(result.relayServer).assertEqual('relay.example.com');
      expect(result.relayPort).assertEqual(21117);
      expect(result.apiServer).assertEqual('https://api.example.com');
      expect(result.key).assertEqual('test-key');
    });

    it('parses_direct_json_and_derives_empty_relay', 0, (): void => {
      const result: RustDeskRelayImportResult = service.parse('json',
        '{"host":"10.0.0.8:21120","relay":"","api":"","key":"abc"}');
      expect(result.ok).assertTrue();
      expect(result.idServer).assertEqual('10.0.0.8');
      expect(result.idServerPort).assertEqual(21120);
      expect(result.relayServer).assertEqual('10.0.0.8');
      expect(result.relayPort).assertEqual(21117);
    });

    it('preserves_json_shared_key_without_trimming', 0, (): void => {
      const rawKey: string = ' =tenant-key:42/abc=\n';
      const result: RustDeskRelayImportResult = service.parse('shared',
        '{"host":"id.example.com:21116","relay":"","key":" =tenant-key:42/abc=\\n"}');
      expect(result.ok).assertTrue();
      expect(result.key).assertEqual(rawKey);
      const resolved = resolveRustDeskRelayKey(result.key, 'auto', false);
      expect(resolved.ok).assertTrue();
      expect(resolved.mode).assertEqual('shared_access_key');
      expect(resolved.value).assertEqual(rawKey);
    });

    it('parses_bracketed_ipv6_endpoints', 0, (): void => {
      const result: RustDeskRelayImportResult = service.parse('ipv6',
        '{"host":"[2001:db8::10]:21116","relay":"[2001:db8::20]:21117"}');
      expect(result.ok).assertTrue();
      expect(result.idServer).assertEqual('2001:db8::10');
      expect(result.relayServer).assertEqual('2001:db8::20');
    });

    it('rejects_empty_or_malformed_config', 0, (): void => {
      expect(service.parse('empty', '').ok).assertFalse();
      expect(service.parse('bad', 'not-rustdesk-config').ok).assertFalse();
    });

    it('rejects_invalid_explicit_ports', 0, (): void => {
      expect(service.parse('bad-id-port', '{"host":"id.example.com:70000","relay":"relay.example.com"}').ok)
        .assertFalse();
      expect(service.parse('bad-relay-port', '{"host":"id.example.com","relay":"[2001:db8::20]:0"}').ok)
        .assertFalse();
    });
  });
}

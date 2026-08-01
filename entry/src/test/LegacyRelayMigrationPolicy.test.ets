import { describe, expect, it } from '@ohos/hypium';
import {
  parseLegacyRelayJson
} from '../main/ets/services/LegacyRelayMigrationPolicy';

export default function legacyRelayMigrationPolicyTest(): void {
  describe('LegacyRelayMigrationPolicy', (): void => {
    it('accepts_a_complete_legacy_relay_container', 0, (): void => {
      const rows = parseLegacyRelayJson(JSON.stringify([{
        id: 'relay-1',
        userId: 'retired-owner-value',
        idServer: 'id.example.test',
        idServerPort: 21116,
        relayServer: 'relay.example.test',
        relayPort: 21117,
        apiPassword: 'legacy-secret',
        accounts: [{
          id: 'account-1',
          relayId: 'relay-1',
          username: 'alice',
          password: 'legacy-account-secret'
        }]
      }]));
      expect(rows !== null).assertTrue();
      expect((rows || []).length).assertEqual(1);
      expect((rows || [])[0].id).assertEqual('relay-1');
    });

    it('rejects_the_entire_container_on_duplicate_or_malformed_rows',
      0, (): void => {
        expect(parseLegacyRelayJson(
          '[{"id":"relay-1"},{"id":"relay-1"}]'))
          .assertNull();
        expect(parseLegacyRelayJson(
          '[{"id":"relay-1","accounts":{"password":"secret"}}]'))
          .assertNull();
        expect(parseLegacyRelayJson('{"id":"relay-1"}'))
          .assertNull();
      });
  });
}

import { describe, expect, it } from '@ohos/hypium';
import {
  LockGateAuthKind,
  lockGateAvailableAuthKinds,
  lockGateRequestedAuthKinds
} from '../main/ets/services/LockGateAuthPolicy';

export default function lockGateAuthPolicyTest(): void {
  describe('LockGateAuthPolicy', (): void => {
    it('admits_pin_fingerprint_and_face_in_one_system_request', 0, (): void => {
      expect(lockGateRequestedAuthKinds('biometric').join(','))
        .assertEqual('pin,fingerprint,face');
      expect(lockGateRequestedAuthKinds('system').join(','))
        .assertEqual('pin,fingerprint,face');
      expect(lockGateRequestedAuthKinds('').join(','))
        .assertEqual('pin,fingerprint,face');
    });

    it('maps_explicit_modes_without_ever_reading_a_lock_screen_password', 0,
      (): void => {
        expect(lockGateRequestedAuthKinds('pin').join(',')).assertEqual('pin');
        expect(lockGateRequestedAuthKinds('password').join(',')).assertEqual('pin');
        expect(lockGateRequestedAuthKinds('fingerprint').join(','))
          .assertEqual('fingerprint');
        expect(lockGateRequestedAuthKinds('face').join(',')).assertEqual('face');
      });

    it('bypasses_only_explicit_none_and_fails_unknown_modes_closed', 0,
      (): void => {
        expect(lockGateRequestedAuthKinds('none').length).assertEqual(0);
        expect(lockGateRequestedAuthKinds('legacy-unknown').join(','))
          .assertEqual('pin,fingerprint,face');
      });

    it('filters_unavailable_types_without_reordering_or_duplicates', 0,
      (): void => {
        const requested: LockGateAuthKind[] = [
          'pin', 'fingerprint', 'face', 'fingerprint'
        ];
        const admitted: LockGateAuthKind[] = lockGateAvailableAuthKinds(
          requested, ['face', 'fingerprint']);
        expect(admitted.join(',')).assertEqual('fingerprint,face');
        expect(requested.join(',')).assertEqual('pin,fingerprint,face,fingerprint');
      });
  });
}

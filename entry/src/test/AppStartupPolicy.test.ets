import { describe, it, expect } from '@ohos/hypium';
import {
  FIRST_LAUNCH_PREPARATION_BLOCKS_UI,
  startupContentPathForAttempt
} from '../main/ets/services/AppStartupPolicy';

export default function appStartupPolicyTest(): void {
  describe('AppStartupPolicy', (): void => {
    it('never_blocks_the_first_install_surface_on_account_preparation', 0, (): void => {
      expect(FIRST_LAUNCH_PREPARATION_BLOCKS_UI).assertFalse();
    });

    it('falls_back_from_the_guide_to_an_interactive_login_page', 0, (): void => {
      expect(startupContentPathForAttempt(0)).assertEqual('pages/GuidePage');
      expect(startupContentPathForAttempt(1)).assertEqual('pages/LoginPage');
      expect(startupContentPathForAttempt(2)).assertEqual('');
      expect(startupContentPathForAttempt(-1)).assertEqual('');
    });
  });
}

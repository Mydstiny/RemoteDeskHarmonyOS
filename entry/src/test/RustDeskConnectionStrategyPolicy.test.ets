import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRustDeskConnectionStrategy,
  rustDeskConnectionStrategyDiagnostic,
  rustDeskConnectionStrategyForHost
} from '../main/ets/services/RustDeskConnectionStrategyPolicy';

export default function rustDeskConnectionStrategyPolicyTest(): void {
  describe('RustDeskConnectionStrategyPolicy', (): void => {
    it('maps_current_host_modes_to_explicit_supported_strategies', 0, (): void => {
      expect(rustDeskConnectionStrategyForHost(false)).assertEqual('force_relay');
      expect(rustDeskConnectionStrategyForHost(true)).assertEqual('direct_ip');
      expect(resolveRustDeskConnectionStrategy('force_relay', false).supported).assertTrue();
      expect(resolveRustDeskConnectionStrategy('direct_ip', true).supported).assertTrue();
    });

    it('fails_closed_instead_of_pretending_force_relay_is_auto', 0, (): void => {
      const result = resolveRustDeskConnectionStrategy('auto', false);
      expect(result.supported).assertFalse();
      expect(result.code).assertEqual('auto_unavailable');
      expect(result.message.indexOf('NAT') >= 0).assertTrue();
    });

    it('rejects_mismatched_or_unknown_cross_layer_values', 0, (): void => {
      expect(resolveRustDeskConnectionStrategy('direct_ip', false).supported).assertFalse();
      expect(resolveRustDeskConnectionStrategy('force_relay', true).supported).assertFalse();
      expect(resolveRustDeskConnectionStrategy('surprise', false).code)
        .assertEqual('invalid_strategy');
    });

    it('keeps_strategy_diagnostics_free_of_endpoints_and_credentials', 0, (): void => {
      const diagnostic = rustDeskConnectionStrategyDiagnostic(
        resolveRustDeskConnectionStrategy('force_relay', false));
      expect(diagnostic).assertEqual('strategy=force_relay, code=ready, supported=yes');
    });
  });
}

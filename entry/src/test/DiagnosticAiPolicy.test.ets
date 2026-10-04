import { describe, it, expect } from '@ohos/hypium';
import {
  diagnosticAiModulesForQuestion,
  diagnosticAiPlanValid
} from '../main/ets/services/diagnosticAi/DiagnosticAiBundlePolicy';
import {
  diagnosticAiOrbTransition,
  diagnosticAiOrbVisible
} from '../main/ets/services/diagnosticAi/DiagnosticAiOrbPolicy';
import { validateDiagnosticAiEndpoint } from '../main/ets/services/diagnosticAi/DiagnosticAiEndpointPolicy';
import { diagnosticAiHarmonyLocalDeviceSupported, diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifests } from '../main/ets/services/diagnosticAi/DiagnosticAiProviderCatalog';
import { diagnosticAiProposalIsSafe } from '../main/ets/services/diagnosticAi/DiagnosticAiSettingsActionPolicy';

export default function diagnosticAiPolicyTest(): void {
  describe('DiagnosticAiPolicy', (): void => {
    it('catalog_has_mainland_and_local_first_entries', 0, (): void => {
      const providers = diagnosticAiProviderManifests();
      expect(providers.some((value) => value.providerId === 'deepseek')).assertTrue();
      expect(providers.some((value) => value.providerId === 'ollama')).assertTrue();
      expect(providers.some((value) => diagnosticAiProviderIsHarmonyLocal(value.providerId) &&
        value.supportedDeviceTypes !== undefined && value.supportedDeviceTypes.indexOf('pc') >= 0 &&
        value.supportedDeviceTypes.indexOf('2in1') >= 0)).assertTrue();
      expect(diagnosticAiHarmonyLocalDeviceSupported('pc')).assertTrue();
      expect(diagnosticAiHarmonyLocalDeviceSupported('tablet')).assertFalse();
    });
    it('endpoint_rejects_query_credentials_and_plain_public_http', 0, (): void => {
      expect(validateDiagnosticAiEndpoint('http://example.com?key=x', 'openai_compatible_http').ok).assertFalse();
      expect(validateDiagnosticAiEndpoint('https://user:pass@example.com', 'openai_compatible_http').ok).assertFalse();
      expect(validateDiagnosticAiEndpoint('http://127.0.0.1:11434', 'ollama_local').ok).assertTrue();
    });
    it('question_maps_to_bounded_protocol_modules', 0, (): void => {
      const modules = diagnosticAiModulesForQuestion('RDP 连接后黑屏');
      expect(modules.indexOf('connection.rdp') >= 0).assertTrue();
      expect(modules.indexOf('network.routing') >= 0).assertTrue();
      expect(diagnosticAiPlanValid({ modules: modules as never[], durationMinutes: 3, consentId: 'consent-123456' })).assertTrue();
    });
    it('orb_requires_pro_config_and_page_activity', 0, (): void => {
      expect(diagnosticAiOrbVisible(true, true, true, true)).assertTrue();
      expect(diagnosticAiOrbVisible(true, false, true, true)).assertFalse();
      const next = diagnosticAiOrbTransition({ state: 'idle', capture: 'idle', generation: 1 }, 'prepareCapture');
      expect(next.state).assertEqual('capturePreparing'); expect(next.capture).assertEqual('arming');
    });
    it('settings_proposal_requires_whitelisted_id_and_confirmation', 0, (): void => {
      expect(diagnosticAiProposalIsSafe({ settingId: 'rdp.showDiagnostics', currentValue: 'off', proposedValue: 'on', reason: '证据显示需要抓取 RDP 事件', evidenceRefs: [], risk: 'low', requiresUserConfirmation: true, rollbackValue: 'off' })).assertTrue();
      expect(diagnosticAiProposalIsSafe({ settingId: 'shell.exec', currentValue: '', proposedValue: 'rm -rf', reason: 'x', evidenceRefs: [], risk: 'high', requiresUserConfirmation: true, rollbackValue: '' })).assertFalse();
    });
  });
}

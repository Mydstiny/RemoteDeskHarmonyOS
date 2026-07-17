/** HostAddDraft.test.ets — modern host-add wizard state regression tests */
import { describe, it, expect } from '@ohos/hypium';
import { HostAddDraft } from '../../../main/ets/model/HostAddDraft';

export default function hostAddDraftTest(): void {
  describe('HostAddDraft', (): void => {
    it('back_navigation_should_preserve_entered_fields', 0, (): void => {
      const draft = new HostAddDraft();
      draft.selectProtocol('rdp');
      draft.label = 'Office PC';
      draft.host = '192.168.1.20';
      draft.nextStep();
      draft.previousStep();
      expect(draft.label).assertEqual('Office PC');
      expect(draft.host).assertEqual('192.168.1.20');
    });

    it('reset_should_remove_unsaved_draft_data', 0, (): void => {
      const draft = new HostAddDraft();
      draft.selectProtocol('ssh');
      draft.label = 'Server';
      draft.reset();
      expect(draft.protocol).assertEqual('');
      expect(draft.label).assertEqual('');
      expect(draft.step).assertEqual(0);
    });

    it('rdp_final_conversion_should_keep_endpoint_and_credentials', 0, (): void => {
      const draft = new HostAddDraft();
      draft.selectProtocol('rdp');
      draft.label = 'Office PC';
      draft.host = '192.168.1.20';
      draft.port = 3390;
      draft.username = 'alice';
      draft.password = 'secret';
      const host = draft.toRemoteHost();
      expect(host.protocol).assertEqual('rdp');
      expect(host.port).assertEqual(3390);
      expect(host.username).assertEqual('alice');
    });
  });
}

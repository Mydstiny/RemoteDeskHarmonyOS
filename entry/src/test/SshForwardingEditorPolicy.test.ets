import { describe, expect, it } from '@ohos/hypium';
import {
  SshForwardingDraft,
  buildSshForwardingProfile,
  defaultSshForwardingDraft,
  makeSshForwardingProfileId,
  sshForwardingProfileNeedsPublicConfirmation
} from '../main/ets/services/SshForwardingEditorPolicy';

export default function sshForwardingEditorPolicyTest(): void {
  describe('SshForwardingEditorPolicy', (): void => {
    it('creates deterministic stable profile ids', 0, (): void => {
      expect(makeSshForwardingProfileId(1234.9, 7)).assertEqual('ssh-forward-1234-7');
    });

    it('builds local remote and dynamic drafts', 0, (): void => {
      const local: SshForwardingDraft = defaultSshForwardingDraft('local', 'local');
      expect(buildSshForwardingProfile(local).valid).assertTrue();
      const remote: SshForwardingDraft = defaultSshForwardingDraft('remote', 'remote');
      expect(buildSshForwardingProfile(remote).valid).assertTrue();
      const dynamic: SshForwardingDraft = defaultSshForwardingDraft('dynamic', 'dynamic');
      expect(buildSshForwardingProfile(dynamic).valid).assertTrue();
      expect(buildSshForwardingProfile(dynamic).profile.targetPort).assertEqual(0);
    });

    it('rejects malformed numeric fields and unconfirmed public binds', 0, (): void => {
      const invalidPort: SshForwardingDraft = defaultSshForwardingDraft('local', 'invalid-port');
      invalidPort.bindPortText = '22x';
      expect(buildSshForwardingProfile(invalidPort).code).assertEqual('E-SSH-FORWARD-BIND-PORT');
      const publicBind: SshForwardingDraft = defaultSshForwardingDraft('dynamic', 'public');
      publicBind.bindHost = '0.0.0.0';
      expect(buildSshForwardingProfile(publicBind).code)
        .assertEqual('E-SSH-FORWARD-PUBLIC-BIND-CONFIRMATION');
      publicBind.allowPublicBind = true;
      const publicProfile = buildSshForwardingProfile(publicBind);
      expect(publicProfile.valid).assertTrue();
      expect(sshForwardingProfileNeedsPublicConfirmation(publicProfile.profile)).assertTrue();
    });
  });
}

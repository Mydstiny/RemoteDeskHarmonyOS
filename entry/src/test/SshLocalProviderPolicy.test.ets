import { describe, it, expect } from '@ohos/hypium';
import {
  canUseSshLocalProviderAction,
  resolveSshLocalProviderPlan,
  resolveSshLocalProviderState,
  SshLocalProviderCapabilities
} from '../main/ets/services/SshLocalProviderPolicy';
import {
  resolveSshLocalFileKind,
  SshLocalFileKind,
  SshLocalFileProvider
} from '../main/ets/services/SshLocalFileProvider';

function capabilities(overrides: Object = {}): SshLocalProviderCapabilities {
  const base: SshLocalProviderCapabilities = {
    folderSelection: false, folderAuthorization: false, folderObtain: false,
    pickerImport: true, pickerExport: true, share: true, externalDrag: false
  };
  const values: Record<string, Object> = overrides as Record<string, Object>;
  if (typeof values['folderSelection'] === 'boolean') {
    base.folderSelection = values['folderSelection'] as boolean;
  }
  if (typeof values['folderAuthorization'] === 'boolean') {
    base.folderAuthorization = values['folderAuthorization'] as boolean;
  }
  if (typeof values['folderObtain'] === 'boolean') {
    base.folderObtain = values['folderObtain'] as boolean;
  }
  if (typeof values['pickerImport'] === 'boolean') {
    base.pickerImport = values['pickerImport'] as boolean;
  }
  if (typeof values['pickerExport'] === 'boolean') {
    base.pickerExport = values['pickerExport'] as boolean;
  }
  if (typeof values['share'] === 'boolean') { base.share = values['share'] as boolean; }
  if (typeof values['externalDrag'] === 'boolean') {
    base.externalDrag = values['externalDrag'] as boolean;
  }
  return base;
}

export default function sshLocalProviderPolicyTest(): void {
  describe('SshLocalProviderPolicy', (): void => {
    it('selects a durable directory provider only when all folder APIs exist', 0, (): void => {
      const plan = resolveSshLocalProviderPlan(capabilities({
        folderSelection: true, folderAuthorization: true, folderObtain: true,
        externalDrag: true
      }));
      expect(plan.kind).assertEqual('directory');
      expect(plan.canPersistAuthorization).assertTrue();
      expect(plan.supportsAtomicReplace).assertFalse();
      expect(resolveSshLocalProviderState(plan, 'unknown')).assertEqual('needsAuthorization');
      expect(resolveSshLocalProviderState(plan, 'granted')).assertEqual('ready');
    });

    it('falls back to the app transfer box without folder authorization', 0, (): void => {
      const plan = resolveSshLocalProviderPlan(capabilities({ externalDrag: true }));
      expect(plan.kind).assertEqual('transferBox');
      expect(plan.supportsAtomicReplace).assertTrue();
      expect(plan.supportsExternalDrag).assertTrue();
      expect(resolveSshLocalProviderState(plan, 'revoked')).assertEqual('ready');
      expect(canUseSshLocalProviderAction(plan, 'ready', 'import')).assertTrue();
      expect(canUseSshLocalProviderAction(plan, 'ready', 'persistAuthorization')).assertFalse();
    });

    it('fails closed when neither folder nor picker capability exists', 0, (): void => {
      const plan = resolveSshLocalProviderPlan(capabilities({ pickerImport: false, pickerExport: false }));
      expect(plan.kind).assertEqual('none');
      expect(resolveSshLocalProviderState(plan, 'granted')).assertEqual('unavailable');
      expect(canUseSshLocalProviderAction(plan, 'ready', 'browse')).assertFalse();
    });

    it('shares_one_authorization_owner_between_page_and_transfer_engine', 0, (): void => {
      const pageProvider: SshLocalFileProvider = SshLocalFileProvider.getInstance();
      const engineProvider: SshLocalFileProvider = SshLocalFileProvider.getInstance();
      expect(pageProvider === engineProvider).assertTrue();
    });

    it('classifies_provider_directory_without_posix_mode_bits', 0, (): void => {
      const kind: SshLocalFileKind = resolveSshLocalFileKind(0, true, false);
      expect(kind.isDirectory).assertTrue();
      expect(kind.isSymbolicLink).assertFalse();
      expect(kind.isSpecialFile).assertFalse();
    });

    it('falls_back_to_posix_mode_bits_when_type_probes_are_unavailable', 0, (): void => {
      const directory: SshLocalFileKind = resolveSshLocalFileKind(0x41ED, false, false);
      const symbolicLink: SshLocalFileKind = resolveSshLocalFileKind(0xA1FF, false, false);
      expect(directory.isDirectory).assertTrue();
      expect(symbolicLink.isSymbolicLink).assertTrue();
    });
  });
}

import { describe, expect, it } from '@ohos/hypium';
import {
  advanceMoonlightHostAddStep,
  applyMoonlightHostAddVerification,
  beginMoonlightHostAddDiscovery,
  beginMoonlightHostAddOperation,
  cancelMoonlightHostAddDiscovery,
  cancelMoonlightHostAddOperation,
  committedMoonlightHostAddId,
  completeMoonlightHostAddCatalog,
  completeMoonlightHostAddPairing,
  completeMoonlightHostAddSave,
  completeMoonlightHostAddTrust,
  createMoonlightHostAddState,
  expireMoonlightHostAddPairingPin,
  failMoonlightHostAddTrust,
  moonlightHostAddDismissDecision,
  moonlightHostAddDiscoveryIsCurrent,
  moonlightHostAddOperationIsCurrent,
  moonlightHostAddPinDigits,
  moonlightHostAddSaveCanBegin,
  MoonlightHostAddBeginResult,
  MoonlightHostAddCandidate,
  MoonlightHostAddDiscoveryBeginResult,
  MoonlightHostAddState,
  MoonlightHostAddTransitionResult,
  MoonlightHostAddVerification,
  parseMoonlightHostAddAddress,
  selectMoonlightHostAddCandidate,
  setMoonlightHostAddDisplayName,
  setMoonlightHostAddPairingPin,
  updateMoonlightHostAddManualAddress
} from '../main/ets/services/MoonlightHostAddFlowPolicy';

function candidate(): MoonlightHostAddCandidate {
  return {
    serverUuid: 'sunshine-server-1',
    displayName: 'Gaming PC',
    address: { host: '192.168.1.20', family: 'ipv4', port: 47989 },
    paired: false,
    reachable: true,
    lastSeenAt: 1000
  };
}

function verification(
  duplicateHostId: string = '',
  certificateChanged: boolean = false
): MoonlightHostAddVerification {
  return {
    serverUuid: 'sunshine-server-1',
    serverName: 'Gaming PC',
    hostType: 'sunshine',
    version: '2026.1',
    address: { host: '192.168.1.20', family: 'ipv4', port: 47989 },
    httpsPort: 48084,
    paired: false,
    fingerprintSha256: 'a'.repeat(64),
    certificateChanged: certificateChanged,
    udpVerified: false,
    duplicateHostId: duplicateHostId
  };
}

function verifiedStepTwo(
  duplicateHostId: string = '',
  certificateChanged: boolean = false
): MoonlightHostAddState {
  let state: MoonlightHostAddState = createMoonlightHostAddState(7);
  state = selectMoonlightHostAddCandidate(state, candidate());
  const begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'verify');
  return applyMoonlightHostAddVerification(
    begin.state, begin.key, verification(duplicateHostId, certificateChanged));
}

export default function moonlightHostAddFlowPolicyTest(): void {
  describe('MoonlightHostAddFlowPolicy', (): void => {
    it('parses_manual_ipv4_hostname_and_bracketed_ipv6_without_accepting_urls', 0, (): void => {
      const ipv4 = parseMoonlightHostAddAddress('192.168.1.20', '47989');
      expect(ipv4.ok).assertTrue();
      expect(ipv4.address.family).assertEqual('ipv4');
      expect(ipv4.canonical).assertEqual('192.168.1.20:47989');

      const hostname = parseMoonlightHostAddAddress('Gaming-PC.local:48000');
      expect(hostname.ok).assertTrue();
      expect(hostname.address.family).assertEqual('hostname');
      expect(hostname.address.host).assertEqual('gaming-pc.local');
      expect(hostname.address.port).assertEqual(48000);

      const ipv6 = parseMoonlightHostAddAddress('[2001:db8::20]:47984');
      expect(ipv6.ok).assertTrue();
      expect(ipv6.address.family).assertEqual('ipv6');
      expect(ipv6.canonical).assertEqual('[2001:db8::20]:47984');

      expect(parseMoonlightHostAddAddress('https://gaming-pc.local').ok).assertFalse();
      expect(parseMoonlightHostAddAddress('192.168.1.999').ok).assertFalse();
      expect(parseMoonlightHostAddAddress(':::1').ok).assertFalse();
      expect(parseMoonlightHostAddAddress('gaming-pc.local', '70000').ok).assertFalse();
    });

    it('keeps_scanning_ephemeral_but_marks_manual_selection_and_identity_as_dirty', 0, (): void => {
      let state: MoonlightHostAddState = createMoonlightHostAddState(7);
      expect(moonlightHostAddDismissDecision(state)).assertEqual('close');

      state = updateMoonlightHostAddManualAddress(state, 'gaming-pc.local', '47989');
      expect(moonlightHostAddDismissDecision(state)).assertEqual('confirm_discard');

      state = createMoonlightHostAddState(7);
      state = selectMoonlightHostAddCandidate(state, candidate());
      expect(moonlightHostAddDismissDecision(state)).assertEqual('confirm_discard');

      state = createMoonlightHostAddState(7);
      state.temporaryIdentityCreated = true;
      expect(moonlightHostAddDismissDecision(state)).assertEqual('confirm_discard');
    });

    it('preserves_user_name_and_routes_duplicate_uuid_to_the_existing_host', 0, (): void => {
      let state: MoonlightHostAddState = createMoonlightHostAddState(7);
      state = selectMoonlightHostAddCandidate(state, candidate());
      state = setMoonlightHostAddDisplayName(state, 'My Living Room');
      const begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'verify');
      state = applyMoonlightHostAddVerification(
        begin.state, begin.key, verification('existing-host'));
      expect(state.step).assertEqual(2);
      expect(state.displayName).assertEqual('My Living Room');
      expect((state.verification as MoonlightHostAddVerification).httpsPort)
        .assertEqual(48084);
      const transition: MoonlightHostAddTransitionResult = advanceMoonlightHostAddStep(state);
      expect(transition.ok).assertFalse();
      expect(transition.errorText.indexOf('已存在') >= 0).assertTrue();
    });

    it('models_pair_trust_catalog_and_local_commit_as_one_four_step_transaction', 0, (): void => {
      let state: MoonlightHostAddState = verifiedStepTwo();
      state = setMoonlightHostAddDisplayName(state, 'Gaming PC');
      let transition: MoonlightHostAddTransitionResult = advanceMoonlightHostAddStep(state);
      expect(transition.ok).assertTrue();
      state = transition.state;
      expect(state.step).assertEqual(3);

      let begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(begin.state, begin.key, '4821', 30000, 1000);
      expect(moonlightHostAddPinDigits(state).join('')).assertEqual('4821');
      state = completeMoonlightHostAddPairing(state, begin.key, true, 2000);
      expect(state.paired).assertTrue();
      expect(state.pairingPin).assertEqual('');

      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = completeMoonlightHostAddTrust(begin.state, begin.key, true);
      expect(state.trustState).assertEqual('trusted');
      transition = advanceMoonlightHostAddStep(state);
      expect(transition.ok).assertTrue();
      state = transition.state;
      expect(state.step).assertEqual(4);

      begin = beginMoonlightHostAddOperation(state, 'catalog');
      state = completeMoonlightHostAddCatalog(begin.state, begin.key, {
        appCount: 2,
        titles: ['Steam', 'Desktop'],
        stale: false,
        errorText: ''
      });
      expect(state.catalog?.appCount).assertEqual(2);

      expect(moonlightHostAddSaveCanBegin(state)).assertTrue();
      begin = beginMoonlightHostAddOperation(state, 'save');
      expect(moonlightHostAddSaveCanBegin(begin.state)).assertFalse();
      state = completeMoonlightHostAddSave(begin.state, begin.key, false, 'disk full');
      expect(state.savedLocally).assertFalse();
      expect(state.errorText).assertEqual('disk full');
      expect(moonlightHostAddSaveCanBegin(state)).assertTrue();
      begin = beginMoonlightHostAddOperation(state, 'save');
      state = completeMoonlightHostAddSave(begin.state, begin.key, true);
      expect(state.savedLocally).assertTrue();
      expect(moonlightHostAddSaveCanBegin(state)).assertFalse();
    });

    it('hands_off_only_a_stable_id_from_a_completed_local_commit', 0, (): void => {
      expect(committedMoonlightHostAddId(true, ' moonlight-host-a '))
        .assertEqual('moonlight-host-a');
      expect(committedMoonlightHostAddId(false, 'moonlight-host-a')).assertEqual('');
      expect(committedMoonlightHostAddId(true, ' ')).assertEqual('');

      let state: MoonlightHostAddState = verifiedStepTwo();
      state = setMoonlightHostAddDisplayName(state, 'Gaming PC');
      state = advanceMoonlightHostAddStep(state).state;
      let begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(begin.state, begin.key, '4821', 30000, 1000);
      state = completeMoonlightHostAddPairing(state, begin.key, true, 2000);
      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = completeMoonlightHostAddTrust(begin.state, begin.key, true);
      state = advanceMoonlightHostAddStep(state).state;
      begin = beginMoonlightHostAddOperation(state, 'save');
      state = completeMoonlightHostAddSave(
        begin.state, begin.key, true,
        '本地主机已保存，但未返回稳定 ID；请在主机列表刷新后打开');
      expect(state.savedLocally).assertTrue();
      expect(state.errorText.indexOf('未返回稳定 ID') >= 0).assertTrue();
      expect(moonlightHostAddSaveCanBegin(state)).assertFalse();
    });

    it('blocks_retry_when_the_local_commit_is_partial_or_uncertain', 0, (): void => {
      let state: MoonlightHostAddState = verifiedStepTwo();
      state = setMoonlightHostAddDisplayName(state, 'Gaming PC');
      state = advanceMoonlightHostAddStep(state).state;
      let begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(begin.state, begin.key, '4821', 30000, 1000);
      state = completeMoonlightHostAddPairing(state, begin.key, true, 2000);
      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = completeMoonlightHostAddTrust(begin.state, begin.key, true);
      state = advanceMoonlightHostAddStep(state).state;
      begin = beginMoonlightHostAddOperation(state, 'save');
      state = completeMoonlightHostAddSave(
        begin.state, begin.key, false, '本地状态不确定', 'partial');
      expect(state.savedLocally).assertFalse();
      expect(state.saveRecoveryRequired).assertTrue();
      expect(moonlightHostAddSaveCanBegin(state)).assertFalse();
    });

    it('rejects_late_async_results_after_cancel_or_owner_change', 0, (): void => {
      let state: MoonlightHostAddState = verifiedStepTwo();
      const begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = cancelMoonlightHostAddOperation(begin.state);
      expect(moonlightHostAddOperationIsCurrent(state, begin.key)).assertFalse();
      const late: MoonlightHostAddState = completeMoonlightHostAddPairing(
        state, begin.key, true, 2000);
      expect(late.paired).assertFalse();

      const anotherOwner: MoonlightHostAddState = createMoonlightHostAddState(8);
      expect(moonlightHostAddOperationIsCurrent(anotherOwner, begin.key)).assertFalse();
    });

    it('clears_expired_pin_and_blocks_changed_certificate', 0, (): void => {
      let state: MoonlightHostAddState = verifiedStepTwo();
      let transition: MoonlightHostAddTransitionResult = advanceMoonlightHostAddStep(state);
      state = transition.state;
      const begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(begin.state, begin.key, '4821', 2000, 1000);
      state = expireMoonlightHostAddPairingPin(state, 2000);
      expect(state.pairingPin).assertEqual('');
      expect(state.activeOperation).assertEqual('none');
      expect(state.errorText.indexOf('失效') >= 0).assertTrue();

      state = verifiedStepTwo('', true);
      transition = advanceMoonlightHostAddStep(state);
      expect(transition.ok).assertFalse();
      expect(transition.errorText.indexOf('证书') >= 0).assertTrue();

      state.step = 3;
      const changedBegin: MoonlightHostAddBeginResult =
        beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(
        changedBegin.state, changedBegin.key, '4821', 3000, 1000);
      state = completeMoonlightHostAddPairing(state, changedBegin.key, true, 2000);
      expect(state.trustState).assertEqual('changed');
    });

    it('never_trusts_without_a_valid_sha256_fingerprint', 0, (): void => {
      let invalid: MoonlightHostAddVerification = verification();
      invalid.fingerprintSha256 = '';
      let state: MoonlightHostAddState = createMoonlightHostAddState(7);
      state = selectMoonlightHostAddCandidate(state, candidate());
      let begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'verify');
      state = applyMoonlightHostAddVerification(begin.state, begin.key, invalid);
      state = advanceMoonlightHostAddStep(state).state;
      state.paired = true;
      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = completeMoonlightHostAddTrust(begin.state, begin.key, true);
      expect(state.trustState).assertEqual('unknown');
      expect(state.errorText.indexOf('指纹') >= 0).assertTrue();
      expect(advanceMoonlightHostAddStep(state).ok).assertFalse();
    });

    it('fences_discovery_results_by_exact_owner_and_generation', 0, (): void => {
      let state: MoonlightHostAddState = createMoonlightHostAddState(7);
      const first: MoonlightHostAddDiscoveryBeginResult =
        beginMoonlightHostAddDiscovery(state);
      state = first.state;
      expect(moonlightHostAddDiscoveryIsCurrent(state, first.key)).assertTrue();

      state = cancelMoonlightHostAddDiscovery(state);
      expect(moonlightHostAddDiscoveryIsCurrent(state, first.key)).assertFalse();
      const second: MoonlightHostAddDiscoveryBeginResult =
        beginMoonlightHostAddDiscovery(state);
      state = second.state;
      expect(second.key.generation === first.key.generation).assertFalse();
      expect(moonlightHostAddDiscoveryIsCurrent(state, first.key)).assertFalse();
      expect(moonlightHostAddDiscoveryIsCurrent(state, second.key)).assertTrue();

      const anotherOwner: MoonlightHostAddState = createMoonlightHostAddState(8);
      expect(moonlightHostAddDiscoveryIsCurrent(anotherOwner, second.key)).assertFalse();
    });

    it('separates_trust_persistence_failure_from_explicit_rejection', 0, (): void => {
      let state: MoonlightHostAddState = verifiedStepTwo();
      state = advanceMoonlightHostAddStep(state).state;
      let begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(begin.state, begin.key, '4821', 3000, 1000);
      state = completeMoonlightHostAddPairing(state, begin.key, true, 2000);

      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = failMoonlightHostAddTrust(begin.state, begin.key);
      expect(state.paired).assertTrue();
      expect(state.trustState).assertEqual('pending');

      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = completeMoonlightHostAddTrust(begin.state, begin.key, false);
      expect(state.paired).assertFalse();
      expect(state.temporaryIdentityCreated).assertFalse();
      expect(state.trustState).assertEqual('rejected');

      begin = beginMoonlightHostAddOperation(state, 'trust');
      state = completeMoonlightHostAddTrust(begin.state, begin.key, true);
      expect(state.trustState).assertEqual('unknown');
      expect(advanceMoonlightHostAddStep(state).ok).assertFalse();
    });

    it('rejects_pairing_completion_at_the_absolute_pin_deadline', 0, (): void => {
      let state: MoonlightHostAddState = verifiedStepTwo();
      state = advanceMoonlightHostAddStep(state).state;
      const begin: MoonlightHostAddBeginResult = beginMoonlightHostAddOperation(state, 'pair');
      state = setMoonlightHostAddPairingPin(begin.state, begin.key, '4821', 2000, 1000);
      state = completeMoonlightHostAddPairing(state, begin.key, true, 2000);
      expect(state.paired).assertFalse();
      expect(state.pairingPin).assertEqual('');
      expect(state.activeOperation).assertEqual('none');
      expect(state.errorText.indexOf('失效') >= 0).assertTrue();
    });
  });
}

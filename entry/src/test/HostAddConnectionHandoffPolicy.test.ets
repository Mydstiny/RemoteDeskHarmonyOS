import { describe, it, expect } from '@ohos/hypium';
import {
  createHostAddPostSaveHandoff,
  emptyHostAddPostSaveHandoff,
  HostAddPostSaveHandoff,
  hostAddPostSaveHandoffIsPending,
  shouldAcceptHostAddSave,
  shouldAcceptHostAddPostSaveHandoff,
  pendingHostIdForHostAddSave,
  shouldStartHostAddConnectionAfterDisappear,
  shouldStartHostAddPostSaveAfterDisappear,
  shouldCloseHostAddAfterCommittedSave
} from '../main/ets/services/HostAddConnectionHandoffPolicy';

export default function hostAddConnectionHandoffPolicyTest(): void {
  describe('HostAddConnectionHandoffPolicy', (): void => {
    it('accepts_only_the_first_save_while_the_add_sheet_is_visible', 0, (): void => {
      expect(shouldAcceptHostAddSave(false, '')).assertTrue();
      expect(shouldAcceptHostAddSave(true, '')).assertFalse();
      expect(shouldAcceptHostAddSave(false, 'host-a')).assertFalse();
    });

    it('keeps_only_a_connect_now_host_id_for_sheet_handoff', 0, (): void => {
      expect(pendingHostIdForHostAddSave(true, 'host-a')).assertEqual('host-a');
      expect(pendingHostIdForHostAddSave(false, 'host-a')).assertEqual('');
      expect(pendingHostIdForHostAddSave(true, '')).assertEqual('');
    });

    it('starts_only_after_the_add_sheet_has_disappeared', 0, (): void => {
      expect(shouldStartHostAddConnectionAfterDisappear(true, false, 'host-a')).assertTrue();
      expect(shouldStartHostAddConnectionAfterDisappear(true, true, 'host-a')).assertFalse();
      expect(shouldStartHostAddConnectionAfterDisappear(false, false, 'host-a')).assertFalse();
      expect(shouldStartHostAddConnectionAfterDisappear(true, false, '')).assertFalse();
    });

    it('accepts_only_one_owner_scoped_post_save_request_during_rapid_taps', 0, (): void => {
      const empty: HostAddPostSaveHandoff = emptyHostAddPostSaveHandoff();
      expect(shouldAcceptHostAddPostSaveHandoff(
        true, false, empty, 7, 7, 'moonlight-host-a')).assertTrue();

      const pending: HostAddPostSaveHandoff = createHostAddPostSaveHandoff(
        'moonlight_catalog', 'moonlight-host-a', 7, 11);
      expect(hostAddPostSaveHandoffIsPending(pending)).assertTrue();
      expect(shouldAcceptHostAddPostSaveHandoff(
        true, false, pending, 7, 7, 'moonlight-host-a')).assertFalse();
      expect(shouldAcceptHostAddPostSaveHandoff(
        true, true, empty, 7, 7, 'moonlight-host-a')).assertFalse();
    });

    it('waits_for_native_sheet_disappear_without_a_fixed_animation_delay', 0, (): void => {
      const pending: HostAddPostSaveHandoff = createHostAddPostSaveHandoff(
        'moonlight_catalog', 'moonlight-host-a', 7, 11);
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, true, 7, 11, pending, 'moonlight_catalog')).assertFalse();
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, false, 7, 11, pending, 'moonlight_catalog')).assertTrue();
    });

    it('routes_existing_moonlight_hosts_only_after_the_same_sheet_boundary', 0, (): void => {
      const pending: HostAddPostSaveHandoff = createHostAddPostSaveHandoff(
        'moonlight_host_detail', 'moonlight-host-a', 7, 12);
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, false, 7, 12, pending, 'moonlight_host_detail')).assertTrue();
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, false, 7, 12, pending, 'moonlight_catalog')).assertFalse();
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, true, 7, 12, pending, 'moonlight_host_detail')).assertFalse();
    });

    it('drops_page_close_stale_owner_and_late_generation_callbacks', 0, (): void => {
      const pending: HostAddPostSaveHandoff = createHostAddPostSaveHandoff(
        'moonlight_catalog', 'moonlight-host-a', 7, 11);
      expect(shouldStartHostAddPostSaveAfterDisappear(
        false, false, 7, 11, pending, 'moonlight_catalog')).assertFalse();
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, false, 8, 11, pending, 'moonlight_catalog')).assertFalse();
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, false, 7, 12, pending, 'moonlight_catalog')).assertFalse();
      expect(shouldStartHostAddPostSaveAfterDisappear(
        true, false, 7, 11, pending, 'none')).assertFalse();
    });

    it('rejects_invalid_or_unstable_post_save_payloads', 0, (): void => {
      expect(hostAddPostSaveHandoffIsPending(createHostAddPostSaveHandoff(
        'moonlight_catalog', ' ', 7, 11))).assertFalse();
      expect(hostAddPostSaveHandoffIsPending(createHostAddPostSaveHandoff(
        'moonlight_catalog', 'moonlight-host-a', 0, 11))).assertFalse();
      expect(hostAddPostSaveHandoffIsPending(createHostAddPostSaveHandoff(
        'moonlight_catalog', 'moonlight-host-a', 7, 0))).assertFalse();
      expect(hostAddPostSaveHandoffIsPending(createHostAddPostSaveHandoff(
        'none', 'moonlight-host-a', 7, 11))).assertFalse();
      expect(shouldAcceptHostAddPostSaveHandoff(
        true, false, emptyHostAddPostSaveHandoff(), 7, 8, 'moonlight-host-a')).assertFalse();
    });

    it('closes_a_committed_save_without_reopening_a_stale_owner', 0, (): void => {
      expect(shouldCloseHostAddAfterCommittedSave(true, false, 7, 7)).assertTrue();
      expect(shouldCloseHostAddAfterCommittedSave(true, true, 7, 7)).assertFalse();
      expect(shouldCloseHostAddAfterCommittedSave(false, false, 7, 7)).assertFalse();
      expect(shouldCloseHostAddAfterCommittedSave(true, false, 7, 8)).assertFalse();
    });
  });
}

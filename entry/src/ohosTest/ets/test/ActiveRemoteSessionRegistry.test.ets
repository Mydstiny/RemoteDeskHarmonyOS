/**
 * ActiveRemoteSessionRegistry.test.ets — 后台保活会话注册表测试 (T-256)
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRecord,
  ActiveRemoteSessionRestoreAdoption,
  ActiveRemoteSessionTermination
} from '../../../main/ets/services/ActiveRemoteSessionRegistry';
import { RemoteProtocol } from '../../../main/ets/services/RemoteSessionState';

function sampleRecord(): ActiveRemoteSessionRecord {
  return {
    ownerScopeId: 'account-a',
    accountGeneration: 1,
    sessionId: 42,
    hostId: 'host-rdp-001',
    protocol: RemoteProtocol.rdp,
    hostAddress: '192.168.31.10',
    protocolConnected: true,
    renderAttached: true,
    restoreNeeded: false,
    latestSurfaceId: 'surface-old',
    createdAtMs: 1000,
    updatedAtMs: 1000
  };
}

export default function activeRemoteSessionRegistryTest(): void {
  describe('ActiveRemoteSessionRegistry', (): void => {
    it('rejects_active_session_before_account_scope_is_bound', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      expect(registry.setActive(sampleRecord())).assertFalse();
      expect(registry.getActive() === null).assertTrue();
    });

    it('set_active_should_be_visible_from_next_instance_reference', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);

      registry.setActive(sampleRecord());

      const nextRegistry = ActiveRemoteSessionRegistry.getInstance();
      const active = nextRegistry.getActive();
      expect(active !== null).assertTrue();
      if (active !== null) {
        expect(active.sessionId).assertEqual(42);
        expect(active.hostId).assertEqual('host-rdp-001');
        expect(active.protocolConnected).assertTrue();
      }
    });

    it('mark_render_detached_should_keep_protocol_and_request_restore', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);
      registry.setActive(sampleRecord());

      registry.markRenderDetached();

      const active = registry.getActive();
      expect(active !== null).assertTrue();
      if (active !== null) {
        expect(active.protocolConnected).assertTrue();
        expect(active.renderAttached).assertFalse();
        expect(active.restoreNeeded).assertTrue();
      }
    });

    it('has_restore_pending_should_match_host_and_session', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);
      registry.setActive(sampleRecord());
      registry.markRenderDetached();

      expect(registry.hasRestorePending('account-a', 1, 'host-rdp-001', 42)).assertTrue();
      expect(registry.hasRestorePending('account-a', 1, 'host-rdp-001', 7)).assertFalse();
      expect(registry.hasRestorePending('account-a', 1, 'other-host', 42)).assertFalse();
    });

    it('mark_render_attached_should_store_latest_surface_and_clear_restore', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);
      registry.setActive(sampleRecord());
      registry.markRenderDetached();

      registry.markRenderAttached('surface-new');

      const active = registry.getActive();
      expect(active !== null).assertTrue();
      if (active !== null) {
        expect(active.renderAttached).assertTrue();
        expect(active.restoreNeeded).assertFalse();
        expect(active.latestSurfaceId).assertEqual('surface-new');
      }
    });

    it('clear_should_remove_active_session', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);
      registry.setActive(sampleRecord());

      registry.clear('test-clear');

      expect(registry.getActive() === null).assertTrue();
    });

    it('latest_restore_adoption_supersedes_older_page_and_completes_after_attach', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);
      registry.setActive(sampleRecord());
      registry.markRenderDetached();
      expect(registry.isRestoreOwnerCurrent(null)).assertTrue();
      const record: ActiveRemoteSessionRecord =
        registry.getActive() as ActiveRemoteSessionRecord;
      const first: ActiveRemoteSessionRestoreAdoption | null =
        registry.beginRestoreAdoption(record);
      const second: ActiveRemoteSessionRestoreAdoption | null =
        registry.beginRestoreAdoption(record);
      expect(first !== null).assertTrue();
      expect(second !== null).assertTrue();
      expect(registry.isRestoreAdoptionCurrent(first)).assertFalse();
      expect(registry.isRestoreAdoptionCurrent(second)).assertTrue();
      expect(registry.isRestoreOwnerCurrent(null)).assertFalse();
      expect(registry.isRestoreOwnerCurrent(first)).assertFalse();
      expect(registry.isRestoreOwnerCurrent(second)).assertTrue();
      expect(registry.markRenderAttached('surface-stale', first)).assertFalse();
      expect(registry.markRenderAttached('surface-unowned')).assertFalse();
      expect(registry.markRenderAttached('surface-restored', second)).assertTrue();
      expect(registry.completeRestoreAdoption(second)).assertTrue();
      expect(registry.isRestoreAdoptionCurrent(second)).assertTrue();
      expect(registry.beginTermination(record, null) === null).assertTrue();
      const termination: ActiveRemoteSessionTermination | null =
        registry.beginTermination(record, second);
      expect(termination !== null).assertTrue();
      expect(registry.completeTermination(termination)).assertTrue();
    });

    it('termination_requires_current_adopter_and_blocks_new_restore_or_mutation', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('account-a', 1);
      registry.setActive(sampleRecord());
      registry.markRenderDetached();
      const record: ActiveRemoteSessionRecord =
        registry.getActive() as ActiveRemoteSessionRecord;
      const first: ActiveRemoteSessionRestoreAdoption | null =
        registry.beginRestoreAdoption(record);
      const second: ActiveRemoteSessionRestoreAdoption | null =
        registry.beginRestoreAdoption(record);
      expect(registry.beginTermination(record, first) === null).assertTrue();
      const termination: ActiveRemoteSessionTermination | null =
        registry.beginTermination(record, second);
      expect(termination !== null).assertTrue();
      expect(registry.isRestoreOwnerCurrent(second)).assertFalse();
      expect(registry.isTerminationCurrent(termination)).assertTrue();
      expect(registry.beginRestoreAdoption(record) === null).assertTrue();
      expect(registry.markRenderAttached('surface-too-late', second)).assertFalse();
      expect(registry.completeTermination(termination)).assertTrue();
      expect(registry.getActive() === null).assertTrue();
    });
  });
}

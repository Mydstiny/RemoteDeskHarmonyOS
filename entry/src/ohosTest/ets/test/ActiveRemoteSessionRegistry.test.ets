/**
 * ActiveRemoteSessionRegistry.test.ets — 后台保活会话注册表测试 (T-256)
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRecord
} from '../../../main/ets/services/ActiveRemoteSessionRegistry';
import { RemoteProtocol } from '../../../main/ets/services/RemoteSessionState';

function sampleRecord(): ActiveRemoteSessionRecord {
  return {
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
    it('set_active_should_be_visible_from_next_instance_reference', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();

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
      registry.setActive(sampleRecord());
      registry.markRenderDetached();

      expect(registry.hasRestorePending('host-rdp-001', 42)).assertTrue();
      expect(registry.hasRestorePending('host-rdp-001', 7)).assertFalse();
      expect(registry.hasRestorePending('other-host', 42)).assertFalse();
    });

    it('mark_render_attached_should_store_latest_surface_and_clear_restore', 0, (): void => {
      const registry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
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
      registry.setActive(sampleRecord());

      registry.clear('test-clear');

      expect(registry.getActive() === null).assertTrue();
    });
  });
}

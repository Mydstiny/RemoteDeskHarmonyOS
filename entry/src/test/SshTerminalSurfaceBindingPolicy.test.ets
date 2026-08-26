import { describe, it, expect } from '@ohos/hypium';
import {
  makeSshTerminalSurfaceBindingKey,
  makeSshTerminalSurfaceOwnerId,
  makeSshTerminalSurfaceRenderKey,
  SSH_TERMINAL_PTY_RESIZE_COALESCE_MS,
  shouldRebindSshTerminalSurface
} from '../main/ets/services/SshTerminalSurfaceBindingPolicy';

export default function sshTerminalSurfaceBindingPolicyTest(): void {
  describe('SshTerminalSurfaceBindingPolicy', (): void => {
    it('keeps_pty_resize_coalescing_inside_the_ssh_performance_contract', 0, (): void => {
      expect(SSH_TERMINAL_PTY_RESIZE_COALESCE_MS >= 50).assertTrue();
      expect(SSH_TERMINAL_PTY_RESIZE_COALESCE_MS <= 100).assertTrue();
    });

    it('rebinds_when_the_platform_reuses_a_surface_id_for_a_new_owner', 0, (): void => {
      expect(shouldRebindSshTerminalSurface('42', '42', 'host-a:binding-1',
        'host-b:binding-2')).assertTrue();
    });

    it('rebinds_when_the_native_surface_id_changes', 0, (): void => {
      expect(shouldRebindSshTerminalSurface('42', '43', 'binding-1', 'binding-1')).assertTrue();
    });

    it('does_not_rebind_an_unchanged_surface_and_owner', 0, (): void => {
      expect(shouldRebindSshTerminalSurface('42', '42', 'binding-1', 'binding-1')).assertFalse();
    });

    it('rebinds_when_the_registry_entry_is_detached', 0, (): void => {
      expect(shouldRebindSshTerminalSurface('', '42', 'binding-1', 'binding-1')).assertTrue();
    });

    it('builds_one_binding_key_for_the_visible_host_and_session', 0, (): void => {
      expect(makeSshTerminalSurfaceBindingKey(' host-a ', 7, 3, 42))
        .assertEqual('host-a:7:3:42');
      expect(makeSshTerminalSurfaceBindingKey('', 7, 3, 42)).assertEqual('');
      expect(makeSshTerminalSurfaceBindingKey('host-a', 7, 3, 0)).assertEqual('');
    });

    it('changes_render_key_for_surface_recovery_and_renderer_mode', 0, (): void => {
      const first: string = makeSshTerminalSurfaceRenderKey('host-a', 'host-a:7:3:42', 1, true);
      const recovered: string = makeSshTerminalSurfaceRenderKey('host-a', 'host-a:7:3:42', 2, true);
      const fallback: string = makeSshTerminalSurfaceRenderKey('host-a', 'host-a:7:3:42', 2, false);
      expect(first === recovered).assertFalse();
      expect(recovered === fallback).assertFalse();
    });

    it('changes_the_registry_owner_lease_for_each_render_revision', 0, (): void => {
      const first: string = makeSshTerminalSurfaceOwnerId('host-a:surface', 1);
      const recovered: string = makeSshTerminalSurfaceOwnerId('host-a:surface', 2);
      expect(first === recovered).assertFalse();
      expect(makeSshTerminalSurfaceOwnerId(' ', 2)).assertEqual('');
    });
  });
}

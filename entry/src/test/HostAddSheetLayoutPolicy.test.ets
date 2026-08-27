import { describe, it, expect } from '@ohos/hypium';
import {
  resolveActiveHostAddProtocol,
  resolveHostAddSheetContentMode,
  resolveHostAddSheetHeightMode,
  resolveHostAddSheetKeyboardAvoidMode
} from '../main/ets/services/HostAddSheetLayoutPolicy';

export default function hostAddSheetLayoutPolicyTest(): void {
  describe('HostAddSheetLayoutPolicy', (): void => {
    it('uses_intrinsic_system_scrolling_sheets_on_phone', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('vnc', 'sm')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('ssh', 'sm')).assertEqual('fit');
      expect(resolveHostAddSheetKeyboardAvoidMode('vnc', 'sm'))
        .assertEqual('translateAndScroll');
      expect(resolveHostAddSheetKeyboardAvoidMode('ssh', 'sm'))
        .assertEqual('translateAndScroll');
      expect(resolveHostAddSheetContentMode('vnc', 'sm')).assertEqual('fitContent');
      expect(resolveHostAddSheetContentMode('ssh', 'sm')).assertEqual('bounded');
    });

    it('keeps_pad_long_flows_usable', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('vnc', 'md')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('ssh', 'md')).assertEqual('large');
      expect(resolveHostAddSheetKeyboardAvoidMode('vnc', 'md'))
        .assertEqual('translateAndScroll');
      expect(resolveHostAddSheetKeyboardAvoidMode('ssh', 'md'))
        .assertEqual('translateAndScroll');
      expect(resolveHostAddSheetContentMode('vnc', 'md')).assertEqual('fitContent');
    });

    it('keeps_pc_long_flows_usable', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('vnc', 'xl')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('ssh', 'xl')).assertEqual('large');
      expect(resolveHostAddSheetKeyboardAvoidMode('vnc', 'xl'))
        .assertEqual('translateAndScroll');
      expect(resolveHostAddSheetKeyboardAvoidMode('ssh', 'xl'))
        .assertEqual('translateAndScroll');
      expect(resolveHostAddSheetContentMode('vnc', 'xl')).assertEqual('fitContent');
    });

    it('routes_classic_protocols_before_resolving_sheet_layout', 0, (): void => {
      expect(resolveActiveHostAddProtocol('', 'vnc', false)).assertEqual('vnc');
      expect(resolveActiveHostAddProtocol('', 'ssh', false)).assertEqual('ssh');
      expect(resolveActiveHostAddProtocol('vnc', 'ssh', false)).assertEqual('vnc');
      expect(resolveActiveHostAddProtocol('', 'vnc', true)).assertEqual('');

      const classicPhoneVnc: string = resolveActiveHostAddProtocol('', 'vnc', false);
      const classicPadSsh: string = resolveActiveHostAddProtocol('', 'ssh', false);
      expect(resolveHostAddSheetContentMode(classicPhoneVnc, 'sm')).assertEqual('fitContent');
      expect(resolveHostAddSheetContentMode(classicPhoneVnc, 'md')).assertEqual('fitContent');
      expect(resolveHostAddSheetContentMode(classicPhoneVnc, 'xl')).assertEqual('fitContent');
      expect(resolveHostAddSheetHeightMode(classicPadSsh, 'md')).assertEqual('large');
    });

    it('keeps_other_host_add_flows_intrinsic', 0, (): void => {
      expect(resolveHostAddSheetHeightMode('', 'sm')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('rdp', 'xl')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('rustdesk', 'xl')).assertEqual('fit');
      expect(resolveHostAddSheetHeightMode('moonlight', 'xl')).assertEqual('fit');
      expect(resolveHostAddSheetKeyboardAvoidMode('rdp', 'sm'))
        .assertEqual('translateAndScroll');
    });
  });
}

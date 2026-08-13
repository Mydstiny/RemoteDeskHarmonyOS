import { describe, expect, it } from '@ohos/hypium';
import {
  dispatchSelectedHostProtocol,
  HOST_PROTOCOL_COMING_SOON_LABEL,
  HostProtocolPickerOptionState,
  resolveHostProtocolPickerIconTint,
  resolveHostProtocolPickerOption,
  resolveMoonlightPickerIconMode,
  selectedHostProtocolRoute
} from '../main/ets/services/HostProtocolPickerPolicy';
import {
  MOONLIGHT_ICON_FALLBACK_SYMBOL,
  moonlightSystemFallbackIcon,
  protocolIconDescriptor
} from '../main/ets/services/ProtocolIconPolicy';

export default function hostProtocolPickerPolicyTest(): void {
  describe('HostProtocolPickerPolicy', (): void => {
    it('keeps_the_moonlight_card_disabled_and_side_effect_free_by_default', 0, (): void => {
      const state: HostProtocolPickerOptionState =
        resolveHostProtocolPickerOption('moonlight', false);
      expect(state.enabled).assertFalse();
      expect(state.routeEnabled).assertFalse();
      expect(state.runtimeAvailable).assertFalse();
      expect(state.shellOnly).assertFalse();
      expect(state.statusLabel).assertEqual(HOST_PROTOCOL_COMING_SOON_LABEL);
      expect(state.opacity).assertEqual(0.58);
      expect(selectedHostProtocolRoute(state)).assertEqual('');
      let selectionCount: number = 0;
      dispatchSelectedHostProtocol(state, (_protocol: string): void => {
        selectionCount += 1;
      });
      expect(selectionCount).assertEqual(0);
    });

    it('uses_the_same_enabled_route_contract_as_rustdesk_after_release', 0, (): void => {
      const rustdesk: HostProtocolPickerOptionState =
        resolveHostProtocolPickerOption('rustdesk', false);
      const moonlight: HostProtocolPickerOptionState =
        resolveHostProtocolPickerOption('moonlight', true);
      expect(rustdesk.enabled).assertTrue();
      expect(moonlight.enabled).assertTrue();
      expect(moonlight.runtimeAvailable).assertTrue();
      expect(moonlight.shellOnly).assertFalse();
      expect(rustdesk.statusLabel).assertEqual('');
      expect(moonlight.statusLabel).assertEqual('');
      expect(rustdesk.opacity).assertEqual(moonlight.opacity);
      expect(selectedHostProtocolRoute(rustdesk)).assertEqual('rustdesk');
      expect(selectedHostProtocolRoute(moonlight)).assertEqual('moonlight');
      let selectedProtocol: string = '';
      dispatchSelectedHostProtocol(moonlight, (protocol: string): void => {
        selectedProtocol = protocol;
      });
      expect(selectedProtocol).assertEqual('moonlight');
    });

    it('keeps_the_route_disabled_when_only_the_visual_shell_is_available', 0, (): void => {
      const state: HostProtocolPickerOptionState =
        resolveHostProtocolPickerOption('moonlight', false, true);
      expect(state.enabled).assertFalse();
      expect(state.routeEnabled).assertFalse();
      expect(state.runtimeAvailable).assertFalse();
      expect(state.shellOnly).assertFalse();
      expect(state.statusLabel).assertEqual(HOST_PROTOCOL_COMING_SOON_LABEL);
      expect(state.opacity).assertEqual(0.58);
      expect(selectedHostProtocolRoute(state)).assertEqual('');
    });

    it('uses_a_tintable_official_geometry_asset_with_a_system_fallback', 0, (): void => {
      const moonlight = protocolIconDescriptor('moonlight');
      const rustdesk = protocolIconDescriptor('rustdesk');
      expect(moonlight.kind).assertEqual('brand');
      expect(moonlight.tintable).assertTrue();
      expect(MOONLIGHT_ICON_FALLBACK_SYMBOL).assertEqual('gamecontroller_fill');
      expect(moonlight.fallbackName).assertEqual(MOONLIGHT_ICON_FALLBACK_SYMBOL);
      expect(JSON.stringify(moonlight.fallback))
        .assertEqual(JSON.stringify(moonlightSystemFallbackIcon()));
      expect(resolveMoonlightPickerIconMode(false)).assertEqual('brand');
      expect(resolveMoonlightPickerIconMode(true)).assertEqual('system-fallback');
      expect(resolveHostProtocolPickerIconTint(true, '#007DFF', '#808080'))
        .assertEqual('#007DFF');
      expect(resolveHostProtocolPickerIconTint(false, '#007DFF', '#808080'))
        .assertEqual('#808080');
      expect(rustdesk.kind).assertEqual('system');
    });
  });
}

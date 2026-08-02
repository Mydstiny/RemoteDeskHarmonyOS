import { describe, it, expect } from '@ohos/hypium';
import { defaultVncSettings, VncSettingsValues } from '../main/ets/services/VncModelPolicy';
import {
  resolveVncHostDefaults,
  VncSelectableGateway
} from '../main/ets/services/VncHostDefaultsPolicy';

function settings(): VncSettingsValues {
  return defaultVncSettings();
}

function gateway(): VncSelectableGateway {
  return {
    id: 'gateway-1', userId: 'user-1', transport: 'ultravnc_repeater',
    repeaterMode: 'mode12', enabled: true
  };
}

export default function vncHostDefaultsPolicyTest(): void {
  describe('VncHostDefaultsPolicy', (): void => {
    it('uses_direct_defaults_without_a_gateway', 0, (): void => {
      const values: VncSettingsValues = settings();
      const result = resolveVncHostDefaults(values, 'user-1', [gateway()]);
      expect(result.transport).assertEqual('direct_tcp');
      expect(result.gatewayId).assertEqual('');
      expect(result.usedFallback).assertFalse();
    });

    it('selects_only_the_requested_valid_mode12_gateway', 0, (): void => {
      const values: VncSettingsValues = settings();
      values.defaultTransport = 'ultravnc_repeater';
      values.defaultGatewayId = 'gateway-1';
      const result = resolveVncHostDefaults(values, 'user-1', [gateway()]);
      expect(result.transport).assertEqual('ultravnc_repeater');
      expect(result.gatewayId).assertEqual('gateway-1');
      expect(result.repeaterMode).assertEqual('mode12');
    });

    it('falls_back_to_direct_when_the_requested_gateway_is_missing_or_invalid', 0, (): void => {
      const values: VncSettingsValues = settings();
      values.defaultTransport = 'ultravnc_repeater';
      values.defaultGatewayId = 'gateway-1';
      const disabled: VncSelectableGateway = gateway();
      disabled.enabled = false;
      const result = resolveVncHostDefaults(values, 'user-1', [disabled]);
      expect(result.transport).assertEqual('direct_tcp');
      expect(result.gatewayId).assertEqual('');
      expect(result.fallbackCode).assertEqual('E-VNC-DEFAULT-GATEWAY');
      expect(resolveVncHostDefaults(values, 'other-user', [gateway()]).usedFallback).assertTrue();
    });

    it('rejects_blank_account_scope_before_gateway_selection', 0, (): void => {
      const values: VncSettingsValues = settings();
      values.defaultTransport = 'ultravnc_repeater';
      values.defaultGatewayId = 'gateway-1';
      const result = resolveVncHostDefaults(values, '  ', [gateway()]);
      expect(result.transport).assertEqual('direct_tcp');
      expect(result.gatewayId).assertEqual('');
      expect(result.usedFallback).assertTrue();
      expect(result.fallbackCode).assertEqual('E-VNC-DEFAULT-OWNER');
    });
  });
}

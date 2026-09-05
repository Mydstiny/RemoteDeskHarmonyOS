import { describe, expect, it } from '@ohos/hypium';
import {
  commitHarmonyShortcutBlockingPreferences,
  decodeHarmonyShortcutBlockingPreferences,
  defaultHarmonyShortcutBlockingPreferences,
  disabledHarmonyShortcutBlockingPreferences,
  encodeHarmonyShortcutBlockingPreferences,
  harmonyShortcutCaptureEligible,
  harmonyShortcutCaptureKeyCodes,
  harmonyShortcutBlockingEnabled,
  harmonyShortcutBlockingSelectionCount,
  harmonyShortcutBlockingSelectionSummary,
  harmonyShortcutDeviceClass,
  harmonyShortcutForgetPressedKey,
  harmonyShortcutMissingSubscriptionKeyCodes,
  harmonyShortcutPressedKeysForRelease,
  harmonyShortcutRememberPressedKey,
  harmonyShortcutUnrequestedSubscriptionKeyCodes,
  HarmonyShortcutPressedKeyIdentity,
  HarmonyShortcutStorageTransactionPort,
  mutateHarmonyShortcutBlockingPreferences,
  readHarmonyShortcutBlockingPreferences,
  withHarmonyShortcutBlockingPreference,
  withHarmonyShortcutDeviceSelection
} from '../main/ets/services/HarmonyShortcutBlockingPolicy';

class FakeHarmonyShortcutStorage implements HarmonyShortcutStorageTransactionPort {
  values: Map<string, string> = new Map<string, string>();
  flushFailures: number = 0;
  readFailures: number = 0;
  mutationCount: number = 0;
  published: string[] = [];

  has(key: string): boolean { return this.values.has(key); }

  get(key: string, fallback: string): string {
    if (this.readFailures > 0) {
      this.readFailures -= 1;
      throw new Error('injected read failure');
    }
    return this.values.get(key) ?? fallback;
  }

  put(key: string, value: string): void {
    this.mutationCount += 1;
    this.values.set(key, value);
  }

  delete(key: string): void {
    this.mutationCount += 1;
    this.values.delete(key);
  }

  flush(): void {
    if (this.flushFailures > 0) {
      this.flushFailures -= 1;
      throw new Error('injected flush failure');
    }
  }

  publish(key: string, value: string): void {
    this.published.push(key + '=' + value);
  }
}

export default function harmonyShortcutBlockingPolicyTest(): void {
  describe('HarmonyShortcutBlockingPolicy', (): void => {
    it('defaults_pc_protocols_to_blocked_and_resolves_physical_device_class', 0, (): void => {
      const defaults = defaultHarmonyShortcutBlockingPreferences();
      expect(harmonyShortcutBlockingSelectionCount(defaults)).assertEqual(4);
      expect(harmonyShortcutBlockingSelectionSummary(defaults)).assertEqual('已启用 4 项');
      expect(harmonyShortcutBlockingEnabled(defaults, 'pc', 'rdp')).assertTrue();
      expect(harmonyShortcutBlockingEnabled(defaults, 'pc', 'rustdesk')).assertTrue();
      expect(harmonyShortcutBlockingEnabled(defaults, 'pc', 'vnc')).assertTrue();
      expect(harmonyShortcutBlockingEnabled(defaults, 'pc', 'moonlight')).assertTrue();
      expect(harmonyShortcutBlockingEnabled(defaults, 'pc', 'ssh')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(defaults, 'phone', 'rdp')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(defaults, 'pad', 'rdp')).assertFalse();
      expect(harmonyShortcutDeviceClass(false, false)).assertEqual('phone');
      expect(harmonyShortcutDeviceClass(false, true)).assertEqual('pad');
      expect(harmonyShortcutDeviceClass(true, true)).assertEqual('pc');
    });

    it('updates_only_the_selected_device_and_protocol', 0, (): void => {
      const updated = withHarmonyShortcutBlockingPreference(
        defaultHarmonyShortcutBlockingPreferences(), 'pad', 'rustdesk', true);
      expect(harmonyShortcutBlockingEnabled(updated, 'pad', 'rustdesk')).assertTrue();
      expect(harmonyShortcutBlockingEnabled(updated, 'phone', 'rustdesk')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(updated, 'pad', 'rdp')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(updated, 'pc', 'rustdesk')).assertTrue();
      expect(harmonyShortcutBlockingSelectionCount(updated)).assertEqual(5);
      expect(harmonyShortcutBlockingSelectionSummary(updated)).assertEqual('已启用 5 项');
    });

    it('round_trips_and_normalizes_the_persisted_matrix', 0, (): void => {
      let updated = withHarmonyShortcutDeviceSelection(
        defaultHarmonyShortcutBlockingPreferences(), 'phone', true);
      updated = withHarmonyShortcutBlockingPreference(updated, 'pc', 'moonlight', false);
      const restored = decodeHarmonyShortcutBlockingPreferences(
        encodeHarmonyShortcutBlockingPreferences(updated));
      expect(harmonyShortcutBlockingSelectionCount(restored)).assertEqual(7);
      expect(harmonyShortcutBlockingEnabled(restored, 'phone', 'ssh')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(restored, 'pad', 'ssh')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(restored, 'pc', 'moonlight')).assertFalse();
      expect(restored.version).assertEqual(1);
    });

    it('fails_closed_for_present_malformed_or_oversized_storage', 0, (): void => {
      const malformedStorage = new FakeHarmonyShortcutStorage();
      malformedStorage.values.set('remoteHarmonyShortcutBlockingV1', '{bad');
      const malformed = readHarmonyShortcutBlockingPreferences(malformedStorage);
      expect(malformed === null).assertFalse();
      if (malformed === null) { return; }
      expect(harmonyShortcutBlockingSelectionCount(malformed)).assertEqual(0);
      const oversized = decodeHarmonyShortcutBlockingPreferences('x'.repeat(4097));
      expect(harmonyShortcutBlockingSelectionCount(oversized)).assertEqual(0);
      expect(harmonyShortcutBlockingEnabled(malformed, 'pc', 'rdp')).assertFalse();
      expect(harmonyShortcutBlockingEnabled(malformed, 'phone', 'unknown')).assertFalse();
    });

    it('uses_pc_defaults_only_for_a_reliably_absent_storage_key', 0, (): void => {
      const absentStorage = new FakeHarmonyShortcutStorage();
      const absent = readHarmonyShortcutBlockingPreferences(absentStorage);
      expect(absent === null).assertFalse();
      if (absent !== null) {
        expect(harmonyShortcutBlockingSelectionCount(absent)).assertEqual(4);
        expect(harmonyShortcutBlockingEnabled(absent, 'pc', 'rdp')).assertTrue();
      }

      const existingStorage = new FakeHarmonyShortcutStorage();
      existingStorage.values.set('remoteHarmonyShortcutBlockingV1',
        encodeHarmonyShortcutBlockingPreferences(
          disabledHarmonyShortcutBlockingPreferences()));
      const existing = readHarmonyShortcutBlockingPreferences(existingStorage);
      expect(existing === null).assertFalse();
      if (existing !== null) {
        expect(harmonyShortcutBlockingSelectionCount(existing)).assertEqual(0);
      }
    });

    it('does_not_replace_an_existing_value_when_the_authoritative_read_fails', 0, (): void => {
      const storage = new FakeHarmonyShortcutStorage();
      storage.values.set('remoteHarmonyShortcutBlockingV1',
        encodeHarmonyShortcutBlockingPreferences(
          disabledHarmonyShortcutBlockingPreferences()));
      storage.readFailures = 1;
      expect(readHarmonyShortcutBlockingPreferences(storage) === null).assertTrue();
      expect(storage.published.length).assertEqual(0);
      expect(storage.mutationCount).assertEqual(0);
    });

    it('keeps_pc_defaults_when_the_first_mutation_creates_storage', 0, (): void => {
      const storage = new FakeHarmonyShortcutStorage();
      const updated = mutateHarmonyShortcutBlockingPreferences(
        storage, 'phone', 'rdp', true);
      expect(updated === null).assertFalse();
      if (updated !== null) {
        expect(harmonyShortcutBlockingSelectionCount(updated)).assertEqual(5);
        expect(harmonyShortcutBlockingEnabled(updated, 'phone', 'rdp')).assertTrue();
        expect(harmonyShortcutBlockingEnabled(updated, 'pc', 'moonlight')).assertTrue();
      }
    });

    it('supports_all_twelve_mappable_device_protocol_cells', 0, (): void => {
      let selected = defaultHarmonyShortcutBlockingPreferences();
      selected = withHarmonyShortcutDeviceSelection(selected, 'phone', true);
      selected = withHarmonyShortcutDeviceSelection(selected, 'pad', true);
      selected = withHarmonyShortcutDeviceSelection(selected, 'pc', true);
      expect(harmonyShortcutBlockingSelectionCount(selected)).assertEqual(12);
      expect(harmonyShortcutBlockingSelectionSummary(selected)).assertEqual('全部设备与可用协议');
      expect(harmonyShortcutBlockingEnabled(selected, 'phone', 'ssh')).assertFalse();
    });

    it('exposes_only_consumer_keys_with_defined_protocol_mappings', 0, (): void => {
      const rdp: number[] = harmonyShortcutCaptureKeyCodes('rdp');
      const rustDeskWindows: number[] = harmonyShortcutCaptureKeyCodes('rustdesk', 'windows');
      const rustDeskMac: number[] = harmonyShortcutCaptureKeyCodes('rustdesk', 'macos');
      expect(rdp.length).assertEqual(5);
      expect(rustDeskWindows.length).assertEqual(2);
      expect(rustDeskMac.length).assertEqual(2);
      expect(rustDeskMac[0]).assertEqual(16);
      expect(rustDeskMac[1]).assertEqual(17);
      expect(harmonyShortcutCaptureKeyCodes('ssh').length).assertEqual(0);
      expect(harmonyShortcutCaptureKeyCodes('unknown').length).assertEqual(0);
    });

    it('publishes_only_after_flush_and_restores_existing_before_image', 0, (): void => {
      const storage = new FakeHarmonyShortcutStorage();
      storage.values.set('remoteHarmonyShortcutBlockingV1', 'before');
      storage.flushFailures = 1;
      const selected = withHarmonyShortcutBlockingPreference(
        defaultHarmonyShortcutBlockingPreferences(), 'pad', 'rdp', true);
      expect(commitHarmonyShortcutBlockingPreferences(storage, selected)).assertFalse();
      expect(storage.values.get('remoteHarmonyShortcutBlockingV1')).assertEqual('before');
      expect(storage.published.length).assertEqual(0);

      expect(commitHarmonyShortcutBlockingPreferences(storage, selected)).assertTrue();
      expect(storage.published.length).assertEqual(1);
      expect(harmonyShortcutBlockingEnabled(decodeHarmonyShortcutBlockingPreferences(
        storage.values.get('remoteHarmonyShortcutBlockingV1') ?? ''),
      'pad', 'rdp')).assertTrue();
    });

    it('restores_absent_key_when_first_flush_fails', 0, (): void => {
      const storage = new FakeHarmonyShortcutStorage();
      storage.flushFailures = 1;
      const selected = withHarmonyShortcutBlockingPreference(
        defaultHarmonyShortcutBlockingPreferences(), 'pc', 'moonlight', false);
      expect(commitHarmonyShortcutBlockingPreferences(storage, selected)).assertFalse();
      expect(storage.values.has('remoteHarmonyShortcutBlockingV1')).assertFalse();
      expect(storage.published.length).assertEqual(0);
    });

    it('never_overwrites_other_cells_when_authoritative_read_fails', 0, (): void => {
      const storage = new FakeHarmonyShortcutStorage();
      let selected = withHarmonyShortcutDeviceSelection(
        defaultHarmonyShortcutBlockingPreferences(), 'phone', true);
      selected = withHarmonyShortcutBlockingPreference(selected, 'pad', 'rdp', true);
      const before: string = encodeHarmonyShortcutBlockingPreferences(selected);
      storage.values.set('remoteHarmonyShortcutBlockingV1', before);
      storage.readFailures = 1;
      expect(mutateHarmonyShortcutBlockingPreferences(
        storage, 'pc', 'moonlight', true) === null).assertTrue();
      expect(storage.values.get('remoteHarmonyShortcutBlockingV1')).assertEqual(before);
      expect(storage.mutationCount).assertEqual(0);
      expect(storage.published.length).assertEqual(0);
    });

    it('mutates_one_cell_from_the_same_authoritative_snapshot', 0, (): void => {
      const storage = new FakeHarmonyShortcutStorage();
      let selected = withHarmonyShortcutDeviceSelection(
        defaultHarmonyShortcutBlockingPreferences(), 'phone', true);
      selected = withHarmonyShortcutBlockingPreference(selected, 'pad', 'rdp', true);
      storage.values.set('remoteHarmonyShortcutBlockingV1',
        encodeHarmonyShortcutBlockingPreferences(selected));
      const updated = mutateHarmonyShortcutBlockingPreferences(
        storage, 'pc', 'moonlight', false);
      expect(updated === null).assertFalse();
      if (updated !== null) {
        expect(harmonyShortcutBlockingSelectionCount(updated)).assertEqual(8);
        expect(harmonyShortcutBlockingEnabled(updated, 'phone', 'rustdesk')).assertTrue();
        expect(harmonyShortcutBlockingEnabled(updated, 'pad', 'rdp')).assertTrue();
        expect(harmonyShortcutBlockingEnabled(updated, 'pc', 'moonlight')).assertFalse();
      }
    });

    it('requires_foreground_focused_ready_unblocked_input_without_modal', 0, (): void => {
      const ready = {
        configured: true,
        foreground: true,
        windowActive: true,
        sessionReady: true,
        inputAllowed: true,
        modalOwnsInput: false
      };
      expect(harmonyShortcutCaptureEligible(ready)).assertTrue();
      expect(harmonyShortcutCaptureEligible({ ...ready, foreground: false })).assertFalse();
      expect(harmonyShortcutCaptureEligible({ ...ready, windowActive: false })).assertFalse();
      expect(harmonyShortcutCaptureEligible({ ...ready, sessionReady: false })).assertFalse();
      expect(harmonyShortcutCaptureEligible({ ...ready, inputAllowed: false })).assertFalse();
      expect(harmonyShortcutCaptureEligible({ ...ready, modalOwnsInput: true })).assertFalse();
      expect(harmonyShortcutCaptureEligible({ ...ready, configured: false })).assertFalse();
    });

    it('deduplicates_repeats_and_plans_owner_switch_releases', 0, (): void => {
      let pressed: HarmonyShortcutPressedKeyIdentity[] = [];
      pressed = harmonyShortcutRememberPressedKey(pressed, 16, 4);
      pressed = harmonyShortcutRememberPressedKey(pressed, 16, 4);
      pressed = harmonyShortcutRememberPressedKey(pressed, 17, 4);
      expect(pressed.length).assertEqual(2);
      const releases: HarmonyShortcutPressedKeyIdentity[] =
        harmonyShortcutPressedKeysForRelease(pressed);
      expect(releases.length).assertEqual(2);
      expect(releases[0].keyCode).assertEqual(16);
      pressed = harmonyShortcutForgetPressedKey(pressed, 16, 4);
      expect(pressed.length).assertEqual(1);
      pressed = harmonyShortcutForgetPressedKey(pressed, 17, 4);
      expect(pressed.length).assertEqual(0);
    });

    it('retries_only_missing_subscriptions_after_partial_registration', 0, (): void => {
      const missing: number[] = harmonyShortcutMissingSubscriptionKeyCodes(
        [10, 12, 13, 16, 17], [10, 13, 17]);
      expect(missing.length).assertEqual(2);
      expect(missing[0]).assertEqual(12);
      expect(missing[1]).assertEqual(16);
    });

    it('retries_only_stale_subscriptions_after_partial_unregistration', 0, (): void => {
      const stale: number[] = harmonyShortcutUnrequestedSubscriptionKeyCodes(
        [16, 17], [10, 12, 16, 17]);
      expect(stale.length).assertEqual(2);
      expect(stale[0]).assertEqual(10);
      expect(stale[1]).assertEqual(12);
    });
  });
}

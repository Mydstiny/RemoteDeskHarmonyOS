import { common } from '@kit.AbilityKit';
import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from
  '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightDesktopFlipPreferenceAdapter,
  MoonlightDesktopFlipPreferenceRead,
  MoonlightDesktopFlipStore,
  moonlightDesktopFlipPreferenceKey,
  setMoonlightDesktopFlipPreferenceAdapterForTest
} from '../main/ets/services/MoonlightDesktopFlipStore';

class FakeFlipPreferenceAdapter implements MoonlightDesktopFlipPreferenceAdapter {
  values: Map<string, string> = new Map<string, string>();
  failWrites: boolean = false;

  read(_context: common.Context, _storeName: string,
    key: string): MoonlightDesktopFlipPreferenceRead {
    const value: string | undefined = this.values.get(key);
    return value === undefined ? { ok: true, value: 'reset' } :
      { ok: true, value: value };
  }

  write(_context: common.Context, _storeName: string,
    key: string, value: string): boolean {
    if (this.failWrites) { return false; }
    this.values.set(key, value);
    return true;
  }
}
export default function moonlightDesktopFlipStoreTest(): void {
  describe('MoonlightDesktopFlipStore', (): void => {
    it('persists_a_per_owner_per_host_mode_and_rejects_failed_writes', 0, (): void => {
      const adapter: FakeFlipPreferenceAdapter = new FakeFlipPreferenceAdapter();
      setMoonlightDesktopFlipPreferenceAdapterForTest(adapter);
      const store: MoonlightDesktopFlipStore = new MoonlightDesktopFlipStore();
      const context: common.Context = {} as common.Context;
      const owner: string = 'a'.repeat(64);
      expect(store.save(context, owner, 'host-a', 'axes_5')).assertTrue();
      expect(store.load(context, owner, 'host-a')).assertEqual('axes_5');
      expect(store.load(context, owner, 'host-b')).assertEqual('reset');
      adapter.failWrites = true;
      expect(store.save(context, owner, 'host-a', 'axes_7')).assertFalse();
      expect(store.load(context, owner, 'host-a')).assertEqual('axes_5');
      setMoonlightDesktopFlipPreferenceAdapterForTest(null);
    });

    it('uses_only_opaque_bounded_key_components', 0, (): void => {
      const key: string = moonlightDesktopFlipPreferenceKey(
        'b'.repeat(64), 'private-host-label.example');
      expect(key.startsWith('moonlight.desktop.flip.v1:')).assertTrue();
      expect(key.indexOf('private-host-label') < 0).assertTrue();
      expect(moonlightDesktopFlipPreferenceKey('bad', 'host')).assertEqual('');
    });
  });
}

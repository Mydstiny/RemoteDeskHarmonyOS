import { describe, it, expect } from '@ohos/hypium';
import {
  SshTerminalRendererBridge,
  SshTerminalRendererConfig
} from '../main/ets/napi/SshTerminalRendererBridge';
import { SshTerminalRendererRegistry } from '../main/ets/services/SshTerminalRendererRegistry';

class FakeRendererBridge {
  nextHandle: number = 41;
  destroyed: number[] = [];

  create(_config: SshTerminalRendererConfig): number {
    this.nextHandle++;
    return this.nextHandle;
  }

  destroy(handle: number): void {
    this.destroyed.push(handle);
  }

  detachSurface(_handle: number): void {
  }

  bindSurface(_handle: number, _surfaceId: string, _widthPx: number,
    _heightPx: number): number {
    return 0;
  }

  hasSurfaceFlushFailure(_handle: number): boolean {
    return false;
  }
}

function bridge(fake: FakeRendererBridge): SshTerminalRendererBridge {
  return fake as Object as SshTerminalRendererBridge;
}

function config(): SshTerminalRendererConfig {
  return {
    surfaceId: 'surface-1',
    widthPx: 800,
    heightPx: 480,
    cols: 80,
    rows: 24,
    cellWidthPx: 9,
    cellHeightPx: 20,
    fontSizePx: 18,
    foreground: 0xFFFFFFFF,
    background: 0xFF000000,
    viewportHeightPx: 480,
    visibleHeightPx: 480,
    bottomAlign: false
  };
}

export default function sshTerminalRendererRegistryTest(): void {
  describe('SshTerminalRendererRegistry', (): void => {
    it('destroys_the_native_handle_when_a_closed_tab_is_removed', 0, (): void => {
      const registry: SshTerminalRendererRegistry = new SshTerminalRendererRegistry();
      const fake: FakeRendererBridge = new FakeRendererBridge();
      const nativeBridge: SshTerminalRendererBridge = bridge(fake);
      const key: string = 'host-a:xterm';
      const handle: number = registry.attach(key, config(), nativeBridge, 'owner-1');
      expect(handle).assertEqual(42);
      expect(registry.handleFor(key)).assertEqual(42);

      registry.destroy(key, nativeBridge);

      expect(fake.destroyed.length).assertEqual(1);
      expect(fake.destroyed[0]).assertEqual(42);
      expect(registry.handleFor(key)).assertEqual(0);
    });

    it('retains_the_handle_when_a_surface_is_only_detached', 0, (): void => {
      const registry: SshTerminalRendererRegistry = new SshTerminalRendererRegistry();
      const fake: FakeRendererBridge = new FakeRendererBridge();
      const nativeBridge: SshTerminalRendererBridge = bridge(fake);
      const key: string = 'host-b:xterm';
      registry.attach(key, config(), nativeBridge, 'owner-1');

      registry.detach(key, nativeBridge, 'owner-1');

      expect(fake.destroyed.length).assertEqual(0);
      expect(registry.handleFor(key)).assertEqual(42);
      registry.destroy(key, nativeBridge);
    });
  });
}

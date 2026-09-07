import { AppIconAdapter } from '../../common/AppIconAdapter';
import { ProAppRuntime } from './ProAppRuntime';
import { ProAppIconController } from './ProAppIconController';

// One application-wide controller serializes system icon mutations across sheets/windows.
export class ProAppIcons {
  private static controller: ProAppIconController;
  static getInstance(): ProAppIconController {
    if (!ProAppIcons.controller) {
      const app = ProAppRuntime.getInstance();
      ProAppIcons.controller = new ProAppIconController(new AppIconAdapter(), app.runtime, () => app.context());
    }
    return ProAppIcons.controller;
  }
}

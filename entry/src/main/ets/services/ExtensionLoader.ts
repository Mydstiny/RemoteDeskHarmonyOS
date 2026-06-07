import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteHost } from '../models/RemoteHost';
import { HostSyncService } from './HostSyncService';

export interface ExtensionManifest {
  name: string;
  version: string;
  extensionPoint: string;
  author: string;
}

export interface ExtensionInstance {
  manifest: ExtensionManifest;
  onRegister: () => void;
  onUnregister?: () => void;
}

export class ExtensionLoader {
  private static instance: ExtensionLoader;
  private loadedExtensions: Map<string, ExtensionInstance> = new Map();
  private pluginDir: string = 'plugins';

  static getInstance(): ExtensionLoader {
    if (!this.instance) {
      this.instance = new ExtensionLoader();
    }
    return this.instance;
  }

  async scanAndLoad(): Promise<ExtensionInstance[]> {
    try {
      const fs = await import('@kit.FileKit');
      const context = getContext();
      const files: string[] = fs.listFileSync(context.filesDir + '/' + this.pluginDir);
      const hspFiles = files.filter((f) => f.endsWith('.hsp'));

      const loaded: ExtensionInstance[] = [];
      for (const file of hspFiles) {
        try {
          const ext = await this.loadSingleExtension(file);
          if (ext) {
            loaded.push(ext);
          }
        } catch (err) {
          console.error('ExtensionLoader failed to load: ' + file + ', error: ' + err);
        }
      }
      console.info('ExtensionLoader loaded ' + loaded.length + ' extensions');
      return loaded;
    } catch (err) {
      console.warn('ExtensionLoader plugin dir not found, skipping');
      return [];
    }
  }

  async loadSingleExtension(fileName: string): Promise<ExtensionInstance | null> {
    try {
      const moduleName = fileName.replace(/\.hsp$/, '');
      const extModule = await import('../plugins/' + moduleName);
      if (!extModule.manifest || !extModule.onRegister) {
        console.warn('ExtensionLoader invalid extension: ' + fileName);
        return null;
      }
      const instance: ExtensionInstance = {
        manifest: extModule.manifest as ExtensionManifest,
        onRegister: extModule.onRegister as () => void
      };
      instance.onRegister();
      this.loadedExtensions.set(instance.manifest.name, instance);
      console.info('ExtensionLoader registered: ' + instance.manifest.name
        + ' v' + instance.manifest.version);
      return instance;
    } catch (err) {
      console.error('ExtensionLoader failed to load extension: ' + fileName + ', ' + err);
      return null;
    }
  }

  unloadExtension(name: string): void {
    const ext = this.loadedExtensions.get(name);
    if (ext) {
      try {
        ext.onUnregister?.();
      } catch (err) {
        console.error('ExtensionLoader unregister failed: ' + name + ', ' + err);
      }
      this.loadedExtensions.delete(name);
      console.info('ExtensionLoader unloaded: ' + name);
    }
  }

  getExtension(name: string): ExtensionInstance | undefined {
    return this.loadedExtensions.get(name);
  }

  getAllExtensions(): ExtensionInstance[] {
    return Array.from(this.loadedExtensions.values());
  }

  getExtensionsByPoint(point: string): ExtensionInstance[] {
    return Array.from(this.loadedExtensions.values())
      .filter((ext) => ext.manifest.extensionPoint === point);
  }

  async exportConnectionsToJson(hosts: RemoteHost[]): Promise<string> {
    const syncService = HostSyncService.getInstance();
    return await syncService.exportToJson(hosts);
  }

  async importConnectionsFromJson(jsonData: string): Promise<RemoteHost[]> {
    const syncService = HostSyncService.getInstance();
    return await syncService.importFromJson(jsonData);
  }

  async exportToFile(hosts: RemoteHost[], filePath: string): Promise<void> {
    const json = await this.exportConnectionsToJson(hosts);
    try {
      const fs = await import('@kit.FileKit');
      const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, json);
      fs.closeSync(file);
      console.info('ExtensionLoader exported ' + hosts.length + ' hosts to ' + filePath);
    } catch (err) {
      console.error('ExtensionLoader export to file failed: ' + err);
    }
  }

  async importFromFile(filePath: string): Promise<RemoteHost[]> {
    try {
      const fs = await import('@kit.FileKit');
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const content = fs.readSync(file.fd);
      fs.closeSync(file);
      return await this.importConnectionsFromJson(content);
    } catch (err) {
      console.error('ExtensionLoader import from file failed: ' + err);
      return [];
    }
  }
}

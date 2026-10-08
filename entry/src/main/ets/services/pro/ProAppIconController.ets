import { AppIconProvider, AppIconState, knownAppIcon } from '../../common/AppIconPolicy';
import { ProRuntime } from './ProRuntime';
import { ProAccessContext } from './ProAccessPolicy';

export interface ProAppIconSnapshot {
  supported: boolean;
  loaded: boolean;
  busy: boolean;
  currentName: string;
  message: string;
}
export class ProAppIconController {
  private provider: AppIconProvider;
  private runtime: ProRuntime;
  private context: () => ProAccessContext;
  private stopRuntime: () => void;
  private accessEpoch: number = 0;
  private queryEpoch: number = 0;
  private loaded: boolean = false;
  private busy: boolean = false;
  private currentName: string = '';
  private message: string = '';
  private listeners: Array<() => void> = [];

  constructor(provider: AppIconProvider, runtime: ProRuntime, context: () => ProAccessContext) {
    this.provider = provider; this.runtime = runtime; this.context = context;
    this.stopRuntime = runtime.subscribe((): void => { this.accessEpoch++; this.publish(); });
  }
  snapshot(): ProAppIconSnapshot {
    return { supported: this.provider.supported(), loaded: this.loaded, busy: this.busy,
      currentName: this.currentName, message: this.message };
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    try { listener(); } catch (_error) {}
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  dispose(): void { this.stopRuntime(); this.queryEpoch++; this.accessEpoch++; this.listeners = []; }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* isolate windows */ }
    });
  }
  private update(icons: AppIconState[]): void {
    const selected = icons.find((icon: AppIconState): boolean => icon.enabled);
    this.currentName = selected ? selected.name : '';
    this.loaded = true;
  }
  async refresh(): Promise<void> {
    if (!this.provider.supported() || this.busy) { return; }
    const epoch = ++this.queryEpoch;
    try {
      const icons = await this.provider.query();
      if (epoch !== this.queryEpoch) { return; }
      this.update(icons); this.message = '';
    } catch (_error) {
      if (epoch !== this.queryEpoch) { return; }
      this.loaded = false; this.message = '暂时无法读取当前图标，请重试。';
    }
    this.publish();
  }
  private allowed(name: string): boolean {
    return name === '' || this.runtime.decision('pro.personalization.appIcon', this.context()).executable;
  }
  async select(name: string, stillOpen: () => boolean): Promise<boolean> {
    if (this.busy || !this.provider.supported() || !knownAppIcon(name) || !stillOpen() || !this.allowed(name)) {
      return false;
    }
    const epoch = this.accessEpoch;
    ++this.queryEpoch; // a stale refresh must not overwrite the mutation result
    this.busy = true; this.message = ''; this.publish();
    let requested: boolean = false;
    try {
      const icons = await this.provider.query();
      if (!stillOpen() || epoch !== this.accessEpoch || !this.allowed(name)) { return false; }
      if (name !== '' && !icons.some((icon: AppIconState): boolean => icon.name === name)) {
        this.message = '当前安装包没有此图标，请更新应用。'; return false;
      }
      // Recheck immediately before the system mutation, after every asynchronous preflight.
      requested = true;
      await this.provider.apply(name);
      this.update(await this.provider.query());
      if (this.currentName !== name) {
        this.loaded = false;
        this.message = '系统尚未确认图标切换，请重试读取。'; return false;
      }
      this.message = name === '' ? '已恢复默认图标。' : '已应用图标。';
      return true;
    } catch (_error) {
      if (requested) { this.loaded = false; }
      this.message = requested ? '已提交切换，暂时无法确认结果，请重试读取。' : '图标切换失败，请稍后重试。';
      return false;
    } finally { this.busy = false; this.publish(); }
  }
}

import { RemoteHost } from '../model/RemoteHost';
import { ProEntries } from '../services/pro/ProEntries';
import {
  applyLayoutPreset, defaultWorkspaceView, MAX_WORKSPACE_ENTRIES, Workspace,
  WorkspaceEntry, WorkspaceLayoutPreset
} from '../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { buildDark, buildLight, Palette } from '../common/Theme';

function emptyWorkspace(): Workspace {
  return { schemaVersion: 1, id: '', name: '', color: '#007DFF', icon: 'desktop', order: 0,
    entries: [], layout: 'custom', updatedAt: 0 };
}

function copyEntry(entry: WorkspaceEntry): WorkspaceEntry {
  const copied: WorkspaceEntry = {
    hostRef: entry.hostRef, protocol: entry.protocol, order: entry.order,
    autoConnect: entry.autoConnect,
    view: {
      sshPane: entry.view.sshPane, sshDirectory: entry.view.sshDirectory, monitor: entry.view.monitor,
      scale: entry.view.scale, panX: entry.view.panX, panY: entry.view.panY, inputMode: entry.view.inputMode
    }
  };
  if (entry.view.strictBounds !== undefined) { copied.view.strictBounds = entry.view.strictBounds; }
  if (entry.frame !== undefined) {
    copied.frame = { x: entry.frame.x, y: entry.frame.y, w: entry.frame.w, h: entry.frame.h, fullscreen: entry.frame.fullscreen };
  }
  return copied;
}

/** In-place Pro workspace editor for entry order, host selection and layout presets. */
@Component
export struct ProWorkspaceEditorPanel {
  @Prop workspace: Workspace = emptyWorkspace();
  @Prop hosts: RemoteHost[] = [];
  onClose: () => void = (): void => {};
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentTheme') theme: string = 'light';
  @State draft: Workspace = emptyWorkspace();
  @State revision: number = 0;

  aboutToAppear(): void { this.draft = this.cloneWorkspace(this.workspace); }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }
  private cloneWorkspace(source: Workspace): Workspace {
    const next: Workspace = { schemaVersion: source.schemaVersion, id: source.id, name: source.name,
      color: source.color, icon: source.icon, order: source.order, entries: [], layout: source.layout,
      updatedAt: source.updatedAt };
    next.entries = source.entries.map((entry: WorkspaceEntry): WorkspaceEntry => copyEntry(entry));
    return next;
  }
  private saveDraft(): void {
    if (!ProEntries.visible('pro.workspaces')) { return; }
    if (!WorkspaceStore.getInstance().save(this.draft)) { return; }
    this.revision++;
  }
  private applyPreset(preset: WorkspaceLayoutPreset): void {
    const next: Workspace = this.cloneWorkspace(this.draft);
    next.entries = applyLayoutPreset(next.entries, preset);
    next.layout = preset;
    this.draft = next;
    this.saveDraft();
  }
  private addHost(host: RemoteHost): void {
    if (this.draft.entries.length >= MAX_WORKSPACE_ENTRIES || this.draft.entries.some((entry: WorkspaceEntry): boolean => entry.hostRef === host.id)) { return; }
    const next: Workspace = this.cloneWorkspace(this.draft);
    next.entries.push({ hostRef: host.id, protocol: host.protocol, order: next.entries.length,
      autoConnect: true, view: defaultWorkspaceView() });
    this.draft = next;
    this.saveDraft();
  }
  private removeEntry(hostRef: string): void {
    const next: Workspace = this.cloneWorkspace(this.draft);
    next.entries = next.entries.filter((entry: WorkspaceEntry): boolean => entry.hostRef !== hostRef);
    next.entries.forEach((entry: WorkspaceEntry, index: number): void => { entry.order = index; });
    this.draft = next;
    this.saveDraft();
  }
  build() {
    Column({ space: 10 }) {
      Row() {
        Text('编辑工作区').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Blank()
        Button('完成').fontSize(12).height(30).borderRadius(15).backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.onClose(); })
      }.width('100%')
      Text(this.draft.name + ' · ' + this.draft.entries.length.toString() + '/' + MAX_WORKSPACE_ENTRIES.toString() + ' 个会话')
        .fontSize(12).fontColor(this.pal().text2)
      Row({ space: 6 }) {
        ForEach((['split', 'columns3', 'masterDetail', 'grid4'] as WorkspaceLayoutPreset[]),
          (preset: WorkspaceLayoutPreset): void => {
            Button(preset === 'split' ? '左右平分' : preset === 'columns3' ? '三栏' : preset === 'masterDetail' ? '主副' : '四宫格')
              .fontSize(11).height(28).borderRadius(14)
              .backgroundColor(this.draft.layout === preset ? this.accentColor : this.pal().surface)
              .fontColor(this.draft.layout === preset ? Color.White : this.pal().text2)
              .onClick((): void => { this.applyPreset(preset); });
          }, (preset: WorkspaceLayoutPreset): string => preset)
      }.width('100%')
      if (this.draft.entries.length > 0) {
        Column({ space: 5 }) {
          ForEach(this.draft.entries, (entry: WorkspaceEntry): void => {
            Row({ space: 8 }) {
              Text(entry.protocol.toUpperCase()).fontSize(10).fontColor(this.accentColor).width(44)
              Text(entry.hostRef).fontSize(12).fontColor(this.pal().text).layoutWeight(1).maxLines(1)
              Text('移除').fontSize(11).fontColor(this.pal().danger).onClick((): void => { this.removeEntry(entry.hostRef); })
            }.width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 }).borderRadius(12).backgroundColor(this.pal().surface)
          }, (entry: WorkspaceEntry): string => entry.hostRef)
        }.width('100%')
      }
      Text('添加主机').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Row({ space: 8 }) {
        ForEach(this.hosts.slice(0, 8), (host: RemoteHost): void => {
          Button(host.label || host.id).fontSize(11).height(28).borderRadius(14).backgroundColor(this.pal().surface)
            .fontColor(this.pal().text2).onClick((): void => { this.addHost(host); });
        }, (host: RemoteHost): string => host.id)
      }.width('100%')
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
  }
}

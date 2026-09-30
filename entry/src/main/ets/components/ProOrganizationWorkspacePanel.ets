import { RemoteHost } from '../model/RemoteHost';
import { ProEntries } from '../services/pro/ProEntries';
import { HostGroupDefinition } from '../services/pro/org/HostOrganizationPolicy';
import { HostOrganizationStore } from '../services/pro/org/HostOrganizationStore';
import { Workspace } from '../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { buildDark, buildLight, Palette } from '../common/Theme';

/** Compact home surface for the two new Pro capabilities; editors build on the same stores. */
@Component
export struct ProOrganizationWorkspacePanel {
  @Prop hosts: RemoteHost[] = [];
  onOpen: (workspace: Workspace) => void = (_workspace: Workspace): void => {};
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentTheme') theme: string = 'light';
  @State revision: number = 0;
  @State groups: HostGroupDefinition[] = [];
  @State workspaces: Workspace[] = [];
  private stopGroups: (() => void) | null = null;
  private stopWorkspaces: (() => void) | null = null;

  aboutToAppear(): void {
    const groups = HostOrganizationStore.getInstance();
    const workspaces = WorkspaceStore.getInstance();
    this.groups = groups.load().groups;
    this.workspaces = workspaces.load();
    this.stopGroups = groups.subscribe((): void => { this.groups = groups.listGroups(); this.revision++; });
    this.stopWorkspaces = workspaces.subscribe((): void => { this.workspaces = workspaces.list(); this.revision++; });
  }
  aboutToDisappear(): void { this.stopGroups?.(); this.stopGroups = null; this.stopWorkspaces?.(); this.stopWorkspaces = null; }
  private groupCount(groupId: string): number { return this.hosts.filter((host: RemoteHost): boolean => host.groupId === groupId).length; }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }
  private newGroup(): void {
    const store = HostOrganizationStore.getInstance();
    const index: number = this.groups.length + 1;
    store.createGroup({ id: 'group-' + Date.now().toString(36), name: '新分组 ' + index.toString(), color: this.accentColor, icon: 'folder', order: this.groups.length, createdAt: 0, updatedAt: 0 });
  }
  private newWorkspace(): void {
    const now: number = Date.now();
    WorkspaceStore.getInstance().save({ schemaVersion: 1, id: 'workspace-' + now.toString(36), name: '新工作区', color: this.accentColor, icon: 'desktop', order: this.workspaces.length, entries: [], layout: 'split', updatedAt: now });
  }
  build() {
    Column({ space: 10 }) {
      if (ProEntries.visible('pro.hostManagement')) {
        Row() {
          Text('高级主机管理').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Blank()
          Button('＋ 分组').fontSize(12).height(30).borderRadius(15).backgroundColor(this.pal().surface).fontColor(this.accentColor).onClick((): void => { this.newGroup(); })
        }.width('100%')
        Row({ space: 8 }) {
          ForEach(this.groups, (group: HostGroupDefinition): void => {
            Text(group.name + ' · ' + this.groupCount(group.id).toString()).fontSize(12).fontColor(this.pal().text2)
              .padding({ left: 11, right: 11, top: 7, bottom: 7 }).borderRadius(16).backgroundColor(this.pal().surface)
          }, (group: HostGroupDefinition): string => group.id)
          if (this.groups.length === 0) { Text('创建分组后可跨协议整理主机').fontSize(12).fontColor(this.pal().text3) }
        }.width('100%')
      }
      if (ProEntries.visible('pro.workspaces')) {
        Row() {
          Text('工作区与布局').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Blank()
          Button('＋ 新建').fontSize(12).height(30).borderRadius(15).backgroundColor(this.pal().surface).fontColor(this.accentColor).onClick((): void => { this.newWorkspace(); })
        }.width('100%')
        Row({ space: 10 }) {
          ForEach(this.workspaces, (workspace: Workspace): void => {
            Column({ space: 4 }) {
              Text(workspace.name).fontSize(13).fontColor(this.pal().text).maxLines(1)
              Text(workspace.entries.length.toString() + ' 个会话 · ' + (workspace.layout || '自定义')).fontSize(11).fontColor(this.pal().text3)
              Button('打开').fontSize(11).height(28).width('100%').borderRadius(14).backgroundColor(this.accentColor).fontColor(Color.White)
                .onClick((): void => { this.onOpen(workspace); })
            }.width(142).padding(10).borderRadius(16).backgroundColor(this.pal().card)
          }, (workspace: Workspace): string => workspace.id)
          if (this.workspaces.length === 0) { Text('保存常用会话组合，支持布局恢复').fontSize(12).fontColor(this.pal().text3) }
        }.width('100%')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 6 }).borderRadius(20).backgroundColor(this.pal().card)
  }
}

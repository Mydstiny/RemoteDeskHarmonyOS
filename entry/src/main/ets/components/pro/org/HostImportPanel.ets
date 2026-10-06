import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import {
  HostExportDocument, HostExportRecord, hostImportKey, hostImportSupported
} from '../../../services/pro/org/HostExportPolicy';
import { HostMembership } from '../../../services/pro/org/HostOrganizationPolicy';
import { HostOrganizationStore } from '../../../services/pro/org/HostOrganizationStore';
import { orgProtocolLabel, OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';

/**
 * Preview of an imported host file. Hosts that already exist can take the file's groups and tags; new RDP, SSH and
 * VNC hosts open the normal add form pre-filled, so credentials are always entered and checked the usual way.
 */
@Component
export struct HostImportPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop document: HostExportDocument = { schemaVersion: 1, exportedAt: 0, groups: [], hosts: [] };
  @Prop rows: OrgHostRow[] = [];
  onAdd: (record: HostExportRecord) => void = (_record: HostExportRecord): void => {};
  onClose: () => void = (): void => {};
  @State applied: boolean = false;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private rowKey(row: OrgHostRow): string {
    return [row.protocol, row.address.trim().toLowerCase(), row.port.toString(), row.username.trim().toLowerCase()].join('|');
  }
  private match(record: HostExportRecord): OrgHostRow | undefined {
    const key: string = hostImportKey(record);
    return this.rows.find((row: OrgHostRow): boolean => this.rowKey(row) === key);
  }
  private existing(): HostExportRecord[] {
    return this.document.hosts.filter((record: HostExportRecord): boolean => this.match(record) !== undefined);
  }
  private withOrganization(): HostExportRecord[] {
    return this.existing().filter((record: HostExportRecord): boolean =>
      (record.groupId ?? '') !== '' || (record.tags ?? []).length > 0);
  }
  private applyOrganization(): void {
    const assignments: Record<string, HostMembership> = {};
    this.withOrganization().forEach((record: HostExportRecord): void => {
      const row: OrgHostRow | undefined = this.match(record);
      if (row !== undefined) {
        assignments[row.ref] = { groupId: record.groupId ?? '', tags: (record.tags ?? []).slice(), updatedAt: 0 };
      }
    });
    const ok: boolean = HostOrganizationStore.getInstance().importOrganization(this.document.groups, assignments);
    this.applied = ok;
    this.getUIContext().getPromptAction().showToast({
      message: ok ? '已把分组与标签应用到 ' + Object.keys(assignments).length.toString() + ' 台主机' : '分组未保存，请稍后重试',
      duration: 2000
    });
  }
  private status(record: HostExportRecord): string {
    if (this.match(record) !== undefined) { return '已存在'; }
    return hostImportSupported(record.protocol) ? '可添加' : '请在应用内手动添加';
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('导入主机').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
          Text(this.document.hosts.length.toString() + ' 台主机 · ' + this.document.groups.length.toString() + ' 个分组 · ' +
            this.existing().length.toString() + ' 台已存在').fontSize(12).fontColor(this.pal().text3)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('完成').fontSize(15).fontColor(this.accent).padding(6).onClick((): void => { this.onClose(); })
      }.width('100%')
      Text('文件不含密码和私钥。新主机会打开添加表单并预填名称、地址和端口，请在表单里填写凭据后保存；保存后回到这里，即可把分组与标签一并应用。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(17).width('100%')
      if (this.withOrganization().length > 0) {
        Button(this.applied ? '已应用，可再次应用' : '把分组与标签应用到 ' + this.withOrganization().length.toString() + ' 台已存在的主机')
          .width('100%').height(42).fontSize(14).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
          .onClick((): void => { this.applyOrganization(); })
      }
      Column() {
        ForEach(this.document.hosts, (record: HostExportRecord, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 14, right: 14 }) }
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(record.label).fontSize(14).fontColor(this.pal().text).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(orgProtocolLabel(record.protocol) + ' · ' + record.host + (record.port > 0 ? ':' + record.port.toString() : '') +
                ((record.tags ?? []).length > 0 ? ' · #' + (record.tags ?? []).join(' #') : ''))
                .fontSize(11).fontColor(this.pal().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.status(record) === '可添加') {
              Button('添加').height(30).fontSize(12).backgroundColor(this.pal().surface).fontColor(this.accent)
                .onClick((): void => { this.onAdd(record); })
            } else {
              Text(this.status(record)).fontSize(11).fontColor(this.pal().text3)
            }
          }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
        }, (record: HostExportRecord, index: number): string => index.toString() + hostImportKey(record) + this.rows.length.toString())
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    }.width('100%')
  }
}

import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { AiSegmented } from './AiSegmented';
import { AI_TOOLS, AiSkill, AiToolSpec, aiParseSkill } from '../../services/diagnosticAi/AiSkillCatalog';
import { AiSkillStore } from '../../services/diagnosticAi/AiSkillStore';

const TABS: string[][] = [['skills', '我的技能'], ['library', '技能库'], ['tools', '工具']];

function sourceLabel(source: string): string {
  if (source === 'custom') { return '自定义'; }
  if (source === 'file') { return '导入'; }
  return '内置';
}

/**
 * 设置 › AI 工具与技能: the tools the AI chat may use (each can be switched off; app data leaves the device only
 * through a tool that is on), the installed skills, the skill library to install more from, and the user's own
 * skills — written here or imported from a SKILL.md / JSON file. Every change applies at once.
 */
@Component
export struct AiSkillsSettingsPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop owner: string = 'device-local';
  @State private tab: string = 'skills';
  @State private toolStates: boolean[] = [];
  @State private installed: AiSkill[] = [];
  @State private library: AiSkill[] = [];
  @State private message: string = '';
  @State private formOpen: boolean = false;
  @State private editingId: string = '';
  @State private formName: string = '';
  @State private formDescription: string = '';
  @State private formInstructions: string = '';
  @State private formStarter: string = '';
  @State private formKeywords: string = '';
  private readonly store: AiSkillStore = new AiSkillStore();

  aboutToAppear(): void {
    this.store.init(this.getUIContext().getHostContext() as common.UIAbilityContext, this.owner);
    this.reload();
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private reload(): void {
    this.toolStates = AI_TOOLS.map((tool: AiToolSpec): boolean => this.store.toolEnabled(tool.id));
    this.installed = this.store.installedSkills();
    this.library = this.store.availableSkills();
  }

  private flash(text: string): void {
    this.message = text;
    setTimeout((): void => { if (this.message === text) { this.message = ''; } }, 2600);
  }

  private setTool(index: number, on: boolean): void {
    this.store.setToolEnabled(AI_TOOLS[index].id, on);
    const next: boolean[] = this.toolStates.slice();
    next[index] = on;
    this.toolStates = next;
  }

  private install(skill: AiSkill): void {
    this.store.install(skill.id);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.reload(); });
    this.flash('已安装「' + skill.name + '」，聊天里可以直接点它');
  }

  private uninstall(skill: AiSkill): void {
    this.store.uninstall(skill.id);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.reload(); });
    this.flash(skill.source === 'builtin' ? '已移除「' + skill.name + '」，可以在技能库里重新安装' : '已删除「' + skill.name + '」');
  }

  private openForm(skill: AiSkill | null): void {
    this.editingId = skill !== null ? skill.id : '';
    this.formName = skill !== null ? skill.name : '';
    this.formDescription = skill !== null ? skill.description : '';
    this.formInstructions = skill !== null ? skill.instructions : '';
    this.formStarter = skill !== null ? skill.starter : '';
    this.formKeywords = skill !== null ? skill.keywords.join('、') : '';
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.formOpen = true; });
  }

  private saveForm(): void {
    const name: string = this.formName.trim();
    const instructions: string = this.formInstructions.trim();
    if (name === '' || instructions === '') { this.flash('请填写技能名称和做法'); return; }
    const id: string = this.editingId !== '' ? this.editingId : 'custom-' + Date.now().toString(36);
    const keywords: string[] = this.formKeywords.split(/[,，、\s]+/).map((word: string): string => word.trim())
      .filter((word: string): boolean => word !== '').slice(0, 12);
    const source: string = this.editingId.startsWith('file-') ? 'file' : 'custom';
    this.store.saveCustom(new AiSkill(id, name.slice(0, 20), this.formDescription.trim().slice(0, 80), instructions.slice(0, 4000),
      this.formStarter.trim().slice(0, 200), keywords, source));
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => {
      this.formOpen = false;
      this.reload();
    });
    this.flash('已保存「' + name + '」');
  }

  /** A SKILL.md, JSON or text file becomes one of the user's skills. */
  private async importSkill(): Promise<void> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['技能文件|.md,.json,.txt'];
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
      if (uris.length === 0) { return; }
      const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const size: number = fileIo.statSync(file.fd).size;
        if (size > 64 * 1024) { this.flash('技能文件太大（上限 64 KB）'); return; }
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(file.fd, buffer);
        text = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true }).decodeToString(new Uint8Array(buffer));
      } finally { fileIo.closeSync(file); }
      const name: string = decodeURIComponent(uris[0].slice(uris[0].lastIndexOf('/') + 1));
      const skill: AiSkill | null = aiParseSkill(text, name, 'file-' + Date.now().toString(36));
      if (skill === null) { this.flash('没有读到技能：需要名称和做法（SKILL.md 的 name 与正文）'); return; }
      this.store.saveCustom(skill);
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => {
        this.tab = 'skills';
        this.reload();
      });
      this.flash('已导入「' + skill.name + '」');
    } catch (_error) {
      this.flash('导入失败，请确认文件是 UTF-8 文本');
    }
  }

  @Builder private pill(label: string, primary: boolean, action: () => void) {
    Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(primary ? Color.White : this.accent)
      .height(32).padding({ left: 14, right: 14 }).borderRadius(16)
      .backgroundColor(primary ? this.accent : this.pal().surface)
      .onClick(action)
  }

  @Builder private toolsView() {
    Text('开启的工具会在聊天需要时读取对应内容，并发送给你选择的 AI 服务；关闭后 AI 就看不到这部分数据。主机地址、账号、密码和密钥从不发送。' +
      '提醒、打电话、写邮件、导航和打开网页都会先显示确认卡片，日程和联系人在系统页面里由你保存。')
      .fontSize(12).lineHeight(18).fontColor(this.pal().text3).width('100%').padding({ left: 4, right: 4 })
    ForEach([['documents', '文档'], ['app', 'App 数据'], ['system', '系统能力']], (group: string[]): void => {
      Text(group[1]).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text3).width('100%')
        .padding({ left: 4, top: 6 })
      Column() {
        ForEach(AI_TOOLS, (tool: AiToolSpec, index: number): void => {
          if (tool.group === group[0]) {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(tool.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                Text(tool.detail).fontSize(12).lineHeight(17).fontColor(this.pal().text3)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.toolStates[index] ?? tool.defaultOn }).selectedColor(this.accent)
                .onChange((on: boolean): void => { this.setTool(index, on); })
            }.width('100%').padding({ top: 12, bottom: 12 })
            .border({ width: { bottom: 0.5 }, color: { bottom: this.pal().divider } })
          }
        }, (tool: AiToolSpec): string => 'tool-' + tool.id)
      }.width('100%').padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
    }, (group: string[]): string => 'group-' + group[0])
  }

  @Builder private skillRow(skill: AiSkill, installed: boolean) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r(skill.needsDocument ? 'sys.symbol.doc_text' : 'sys.symbol.wand_and_stars')).fontSize(18)
          .fontColor([this.accent])
      }.width(38).height(38).borderRadius(12).backgroundColor(this.pal().surface)
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(skill.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text(sourceLabel(skill.source)).fontSize(10).fontColor(this.pal().text3)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 }).borderRadius(6).backgroundColor(this.pal().surface)
        }
        Text(skill.description !== '' ? skill.description : skill.instructions).fontSize(12).lineHeight(17)
          .fontColor(this.pal().text3).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!installed) {
        this.pill('安装', true, (): void => { this.install(skill); })
      } else {
        Column({ space: 6 }) {
          if (skill.source !== 'builtin') {
            Text('编辑').fontSize(13).fontColor(this.accent).onClick((): void => { this.openForm(skill); })
          }
          Text(skill.source === 'builtin' ? '移除' : '删除').fontSize(13).fontColor(this.pal().danger)
            .onClick((): void => { this.uninstall(skill); })
        }.alignItems(HorizontalAlign.End)
      }
    }.width('100%').padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: { bottom: this.pal().divider } })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 16 })))
  }

  @Builder private formView() {
    Column({ space: 10 }) {
      Text(this.editingId !== '' ? '编辑技能' : '新建技能').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .width('100%')
      TextInput({ placeholder: '名称，例如“项目周报”', text: this.formName }).height(42).fontSize(14)
        .backgroundColor(this.pal().surface).borderRadius(12).maxLength(20)
        .onChange((value: string): void => { this.formName = value; })
      TextInput({ placeholder: '一句话说明它做什么（可选）', text: this.formDescription }).height(42).fontSize(14)
        .backgroundColor(this.pal().surface).borderRadius(12).maxLength(80)
        .onChange((value: string): void => { this.formDescription = value; })
      TextArea({ placeholder: '做法：告诉 AI 怎么完成，例如“按 本周完成 / 下周计划 两部分写，生成 Word”', text: this.formInstructions })
        .height(120).fontSize(14).backgroundColor(this.pal().surface).borderRadius(12)
        .onChange((value: string): void => { this.formInstructions = value; })
      TextInput({ placeholder: '点它时填进输入框的话（可选）', text: this.formStarter }).height(42).fontSize(14)
        .backgroundColor(this.pal().surface).borderRadius(12)
        .onChange((value: string): void => { this.formStarter = value; })
      TextInput({ placeholder: '触发词，用顿号分隔（可选），例如“项目周报、进展”', text: this.formKeywords }).height(42).fontSize(14)
        .backgroundColor(this.pal().surface).borderRadius(12)
        .onChange((value: string): void => { this.formKeywords = value; })
      Row({ space: 10 }) {
        Button('取消').height(40).layoutWeight(1).borderRadius(20).backgroundColor(this.pal().surface).fontColor(this.pal().text)
          .onClick((): void => {
            this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.formOpen = false; });
          })
        Button('保存').height(40).layoutWeight(1).borderRadius(20).backgroundColor(this.accent).fontColor(Color.White)
          .onClick((): void => { this.saveForm(); })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -10 })))
  }

  build() {
    Column({ space: 12 }) {
      AiSegmented({ options: TABS, current: this.tab, trackColor: this.pal().surface, thumbColor: this.pal().card,
        textColor: this.pal().text, mutedColor: this.pal().text3,
        onPick: (id: string): void => {
          this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.tab = id; });
        } })
      if (this.message !== '') {
        Text(this.message).fontSize(12).fontColor(this.accent).width('100%').padding({ left: 4 })
      }
      Scroll() {
        Column({ space: 10 }) {
          if (this.tab === 'tools') {
            this.toolsView()
          } else if (this.tab === 'library') {
            Text('安装后，技能会出现在聊天输入框下方；说到相关的事时 AI 也会自动按技能的做法完成。')
              .fontSize(12).lineHeight(18).fontColor(this.pal().text3).width('100%').padding({ left: 4, right: 4 })
            if (this.library.length === 0) {
              Text('技能库里的技能都已安装').fontSize(13).fontColor(this.pal().text3).width('100%')
                .textAlign(TextAlign.Center).padding({ top: 24 })
            } else {
              Column() {
                ForEach(this.library, (skill: AiSkill): void => { this.skillRow(skill, false) },
                  (skill: AiSkill): string => 'lib-' + skill.id)
              }.width('100%').padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder })
            }
          } else {
            Row({ space: 10 }) {
              this.pill('新建技能', true, (): void => { this.openForm(null); })
              this.pill('从文件导入', false, (): void => { void this.importSkill(); })
              Blank()
            }.width('100%')
            if (this.formOpen) {
              this.formView()
            }
            if (this.installed.length === 0) {
              Text('还没有技能。可以在技能库里安装，或新建自己的技能。').fontSize(13).fontColor(this.pal().text3).width('100%')
                .textAlign(TextAlign.Center).padding({ top: 24 })
            } else {
              Column() {
                ForEach(this.installed, (skill: AiSkill): void => { this.skillRow(skill, true) },
                  (skill: AiSkill): string => 'mine-' + skill.id + '-' + skill.name)
              }.width('100%').padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder })
            }
            Text('导入格式：SKILL.md（开头 --- 之间写 name、description、starter、keywords，正文写做法），或含同名字段的 JSON。')
              .fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%').padding({ left: 4, right: 4 })
          }
        }.width('100%').padding({ bottom: 16 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    }.layoutWeight(1).width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

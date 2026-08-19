/** Lightweight semantic controls around one terminal pane. */
@Component
export struct SshWorkspacePaneChrome {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop title: string = '';
  @Prop status: string = '';
  @Prop active: boolean = false;
  @Prop focused: boolean = false;
  @Prop compact: boolean = false;
  @Prop canSplit: boolean = false;
  @Prop canMerge: boolean = false;
  @Prop canCycle: boolean = false;
  @Prop canAdjustRatio: boolean = false;
  onActivate: () => void = (): void => {};
  onSplitHorizontal: () => void = (): void => {};
  onSplitVertical: () => void = (): void => {};
  onCycleTab: () => void = (): void => {};
  onToggleFocus: () => void = (): void => {};
  onMerge: () => void = (): void => {};
  onAdjustRatio: (delta: number) => void = (_delta: number): void => {};

  @Builder
  private Action(label: string, description: string, enabled: boolean,
    action: () => void) {
    Button(label)
      .width(48)
      .height(48)
      .padding(0)
      .fontSize(12)
      .fontColor(enabled ? 'rgba(244,247,250,0.86)' : 'rgba(244,247,250,0.28)')
      .borderRadius(10)
      .backgroundColor('rgba(255,255,255,0.06)')
      .enabled(enabled)
      .onClick(action)
      .accessibilityText(description)
  }

  build() {
    Row({ space: 4 }) {
      Row({ space: 6 }) {
        Column().width(6).height(6).borderRadius(3)
          .backgroundColor(this.active ? this.accentColor : 'rgba(244,247,250,0.35)')
        Column({ space: 1 }) {
          Text(this.title.length > 0 ? this.title : 'SSH')
            .fontSize(11)
            .fontWeight(this.active ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.active ? '#F4F7FA' : 'rgba(244,247,250,0.72)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.compact && this.status.length > 0) {
            Text(this.status).fontSize(8).fontColor('rgba(244,247,250,0.42)').maxLines(1)
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .layoutWeight(1)
      .height(48)
      .onClick((): void => { this.onActivate(); })

      if (this.canAdjustRatio && !this.compact) {
        this.Action('−', '缩小当前 Pane', true, (): void => { this.onAdjustRatio(-0.05); })
        this.Action('＋', '放大当前 Pane', true, (): void => { this.onAdjustRatio(0.05); })
      }
      this.Action('⇥', '切换当前 Pane 中的标签', this.canCycle,
        (): void => { this.onCycleTab(); })
      if (!this.compact) {
        this.Action('↔', '水平分屏', this.canSplit,
          (): void => { this.onSplitHorizontal(); })
        this.Action('↕', '垂直分屏', this.canSplit,
          (): void => { this.onSplitVertical(); })
      }
      this.Action(this.focused ? '⊙' : '□', this.focused ? '退出焦点模式' : '进入焦点模式',
        true, (): void => { this.onToggleFocus(); })
      this.Action('×', '合并并关闭当前 Pane', this.canMerge,
        (): void => { this.onMerge(); })
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 4 })
    .backgroundColor(this.active ? 'rgba(0,125,255,0.18)' : 'rgba(19,24,31,0.96)')
    .border({ width: { bottom: 0.5 }, color: 'rgba(255,255,255,0.09)' })
  }
}

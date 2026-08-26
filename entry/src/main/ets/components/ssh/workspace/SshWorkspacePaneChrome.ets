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
  @State actionMenuVisible: boolean = false;
  onActivate: () => void = (): void => {};
  onSplitHorizontal: () => void = (): void => {};
  onSplitVertical: () => void = (): void => {};
  onCycleTab: () => void = (): void => {};
  onToggleFocus: () => void = (): void => {};
  onMerge: () => void = (): void => {};
  onAdjustRatio: (delta: number) => void = (_delta: number): void => {};

  private showSplitActions(): boolean {
    return this.canSplit && !this.compact && !this.focused;
  }

  private showRatioActions(): boolean {
    return this.canAdjustRatio && !this.compact && !this.focused;
  }

  private hasPaneActions(): boolean {
    return this.canCycle || this.showSplitActions() || this.showRatioActions() ||
      this.canMerge || this.focused;
  }

  private runMenuAction(action: () => void): void {
    this.actionMenuVisible = false;
    action();
  }

  @Builder
  private MenuAction(label: string, description: string, danger: boolean,
    action: () => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Regular)
        .fontColor(danger ? '#FF8989' : 'rgba(244,247,250,0.92)')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 14 })
    .borderRadius(8)
    .onClick((): void => { this.runMenuAction(action); })
    .accessibilityText(description)
  }

  @Builder
  private RatioActions() {
    Row({ space: 2 }) {
      Text('调整 Pane 比例')
        .fontSize(13)
        .fontColor('rgba(244,247,250,0.92)')
        .layoutWeight(1)
        .maxLines(1)
      Button('−')
        .width(48).height(48).padding(0)
        .fontSize(17).fontColor('rgba(244,247,250,0.88)')
        .borderRadius(8).backgroundColor('rgba(255,255,255,0.06)')
        .onClick((): void => {
          this.runMenuAction((): void => { this.onAdjustRatio(-0.05); });
        })
        .accessibilityText('缩小当前 Pane')
      Button('＋')
        .width(48).height(48).padding(0)
        .fontSize(17).fontColor('rgba(244,247,250,0.88)')
        .borderRadius(8).backgroundColor('rgba(255,255,255,0.06)')
        .onClick((): void => {
          this.runMenuAction((): void => { this.onAdjustRatio(0.05); });
        })
        .accessibilityText('放大当前 Pane')
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 4 })
  }

  @Builder
  private PaneActionMenu() {
    Column({ space: 2 }) {
      if (this.canCycle) {
        this.MenuAction('切换此 Pane 的标签', '切换当前 Pane 中的标签', false,
          (): void => { this.onCycleTab(); })
      }
      if (this.showSplitActions()) {
        this.MenuAction('左右分屏', '创建左右分屏', false,
          (): void => { this.onSplitHorizontal(); })
        this.MenuAction('上下分屏', '创建上下分屏', false,
          (): void => { this.onSplitVertical(); })
      }
      if (this.showRatioActions()) {
        this.RatioActions()
      }
      if (this.canMerge || this.focused) {
        this.MenuAction(this.focused ? '退出专注模式' : '专注当前 Pane',
          this.focused ? '退出 Pane 专注模式' : '进入 Pane 专注模式', false,
          (): void => { this.onToggleFocus(); })
      }
      if (this.canMerge) {
        Divider().strokeWidth(0.5).color('rgba(255,255,255,0.10)').width('100%')
        this.MenuAction('合并并关闭当前 Pane', '合并并关闭当前 Pane', true,
          (): void => { this.onMerge(); })
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .borderRadius(12)
    .backgroundColor('#1A2028')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.scale({ x: 0.88, y: 0.88 }).combine(TransitionEffect.OPACITY)
        .animation({ duration: 180, curve: Curve.FastOutSlowIn }),
      TransitionEffect.scale({ x: 0.88, y: 0.88 }).combine(TransitionEffect.OPACITY)
        .animation({ duration: 130, curve: Curve.FastOutSlowIn })
    ))
  }

  build() {
    Row() {
      Row({ space: 8 }) {
        Column().width(3).height(18).borderRadius(2)
          .backgroundColor(this.active ? this.accentColor : 'rgba(244,247,250,0.16)')
        Column({ space: 1 }) {
          Text(this.title.length > 0 ? this.title : 'SSH')
            .fontSize(12)
            .fontWeight(this.active ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.active ? '#F4F7FA' : 'rgba(244,247,250,0.72)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.compact && this.status.length > 0) {
            Row({ space: 6 }) {
              Text(this.status)
                .fontSize(9).fontColor('rgba(244,247,250,0.48)').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.focused) {
                Text('专注')
                  .fontSize(8).fontColor(this.accentColor)
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .borderRadius(5).backgroundColor(this.accentColor + '20')
              }
            }
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .layoutWeight(1)
      .height(48)
      .onClick((): void => { this.onActivate(); })

      if (this.hasPaneActions()) {
        Button() {
          Text('⋯').fontSize(18).fontColor('rgba(244,247,250,0.86)')
        }
        .width(48).height(48).padding(0)
        .borderRadius(8)
        .backgroundColor(this.actionMenuVisible ? this.accentColor + '28' : Color.Transparent)
        .bindPopup(this.actionMenuVisible, {
          builder: this.PaneActionMenu(),
          placement: Placement.BottomRight,
          enableArrow: true,
          popupColor: '#1A2028',
          width: 224,
          onStateChange: (event: Object): void => {
            const state: Record<string, boolean> = event as Record<string, boolean>;
            if (!state['isVisible']) { this.actionMenuVisible = false; }
          }
        })
        .onClick((): void => {
          animateTo({ duration: 160, curve: Curve.FastOutSlowIn }, (): void => {
            this.actionMenuVisible = !this.actionMenuVisible;
          });
        })
        .accessibilityText('打开当前 Pane 操作菜单')
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 4 })
    .backgroundColor(this.active ? 'rgba(20,27,35,0.98)' : 'rgba(15,20,26,0.96)')
    .border({ width: { bottom: 0.5 }, color: 'rgba(255,255,255,0.09)' })
  }
}

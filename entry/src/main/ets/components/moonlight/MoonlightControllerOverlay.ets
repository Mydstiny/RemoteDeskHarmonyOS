export interface MoonlightControllerSemanticState {
  sourceGeneration: number;
  buttons: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
  leftTrigger: number;
  rightTrigger: number;
  neutral: boolean;
}

function neutralState(generation: number): MoonlightControllerSemanticState {
  return {
    sourceGeneration: generation, buttons: 0,
    leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0,
    leftTrigger: 0, rightTrigger: 0, neutral: true
  };
}

@Component
export struct MoonlightControllerOverlay {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop inputCapabilityReady: boolean = false;
  @Prop editing: boolean = false;
  @Prop physicalControllerName: string = '';
  @Prop physicalControllerSlot: number = -1;
  @Prop sourceGeneration: number = 0;
  @State private activeButton: string = '';
  onSemanticState: (state: MoonlightControllerSemanticState) => void =
    (_state: MoonlightControllerSemanticState): void => {};
  onClose: () => void = (): void => {};
  onEditToggle: () => void = (): void => {};

  private buttonMask(label: string): number {
    if (label === 'A') { return 1; }
    if (label === 'B') { return 2; }
    if (label === 'X') { return 4; }
    if (label === 'Y') { return 8; }
    if (label === 'LB') { return 16; }
    if (label === 'RB') { return 32; }
    if (label === '菜单') { return 64; }
    if (label === '上') { return 128; }
    if (label === '下') { return 256; }
    if (label === '左') { return 512; }
    if (label === '右') { return 1024; }
    return 0;
  }

  private press(label: string): void {
    if (!this.inputCapabilityReady || this.editing) { return; }
    this.activeButton = label;
    const state: MoonlightControllerSemanticState = neutralState(this.sourceGeneration);
    if (label === 'LT') { state.leftTrigger = 1; }
    else if (label === 'RT') { state.rightTrigger = 1; }
    else { state.buttons = this.buttonMask(label); }
    state.neutral = false;
    this.onSemanticState(state);
  }

  private release(): void {
    this.activeButton = '';
    if (this.inputCapabilityReady && !this.editing) {
      this.onSemanticState(neutralState(this.sourceGeneration));
    }
  }

  @Builder private faceButton(label: string, color: string) {
    Button(label).width(48).height(48).borderRadius(24).fontSize(14).fontWeight(FontWeight.Bold)
      .backgroundColor(this.activeButton === label ? color : 'rgba(255,255,255,0.12)')
      .fontColor('#FFFFFF').enabled(this.inputCapabilityReady && !this.editing)
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) { this.press(label); }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.release(); }
      })
      .accessibilityText(label + ' 键')
  }

  @Builder private stick(label: string) {
    Stack({ alignContent: Alignment.Center }) {
      Column().width(104).height(104).borderRadius(52)
        .backgroundColor('rgba(255,255,255,0.08)')
        .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
      Column().width(54).height(54).borderRadius(27)
        .backgroundColor('rgba(255,255,255,0.22)')
      Text(label).fontSize(10).fontColor('rgba(255,255,255,0.64)')
    }.width(112).height(112).opacity(this.inputCapabilityReady && !this.editing ? 1 : 0.55)
  }

  @Builder private dpadButton(label: string) {
    Button(label).width(34).height(34).borderRadius(9).fontSize(12).fontWeight(FontWeight.Bold)
      .backgroundColor(this.activeButton === label ? this.accentColor : 'rgba(255,255,255,0.12)')
      .fontColor('#FFFFFF').enabled(this.inputCapabilityReady && !this.editing)
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) { this.press(label); }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.release(); }
      }).accessibilityText('方向键' + label)
  }

  @Builder private dpad() {
    Column({ space: 2 }) {
      this.dpadButton('上')
      Row({ space: 2 }) {
        this.dpadButton('左')
        Column().width(34).height(34).borderRadius(9).backgroundColor('rgba(255,255,255,0.07)')
        this.dpadButton('右')
      }
      this.dpadButton('下')
    }.width(106)
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('虚拟控制器').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Text(this.physicalControllerName === '' ? '未检测到实体手柄' :
            this.physicalControllerName + ' · 槽位 ' + (this.physicalControllerSlot + 1).toString())
            .fontSize(10).fontColor('rgba(255,255,255,0.60)').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.editing ? '完成布局' : '编辑布局').height(34).fontSize(11).borderRadius(10)
          .backgroundColor('rgba(255,255,255,0.10)').fontColor('#FFFFFF')
          .onClick((): void => { this.release(); this.onEditToggle(); })
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor(['#FFFFFF']) }
          .width(34).height(34).borderRadius(17).backgroundColor('rgba(255,255,255,0.10)')
          .margin({ left: 8 }).onClick((): void => { this.release(); this.onClose(); })
      }.width('100%')

      if (!this.inputCapabilityReady) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill')).fontSize(16).fontColor(['#FFCF70'])
          Text('真实 HarmonyOS GameController native listener 与 typed NAPI 验证完成前不发送手柄信号。')
            .fontSize(10).fontColor('rgba(255,255,255,0.72)').layoutWeight(1).margin({ left: 8 })
        }.width('100%').padding(10).margin({ top: 12 })
          .backgroundColor('rgba(255,190,80,0.10)').borderRadius(10)
      }

      Row() {
        this.faceButton('LT', '#6E8EFF')
        this.faceButton('LB', '#6E8EFF')
        Blank().layoutWeight(1)
        Text('完整状态由 native 聚合').fontSize(9).fontColor('rgba(255,255,255,0.48)')
        Blank().layoutWeight(1)
        this.faceButton('RB', '#6E8EFF')
        this.faceButton('RT', '#6E8EFF')
      }.width('100%').margin({ top: 14 })

      Row() {
        Column({ space: 10 }) {
          this.dpad()
          this.stick('左摇杆')
        }
        Blank().layoutWeight(1)
        Column({ space: 8 }) {
          this.faceButton('Y', '#D6B83D')
          Row({ space: 48 }) { this.faceButton('X', '#4B9DE8'); this.faceButton('B', '#E65D5D') }
          this.faceButton('A', '#56B870')
        }.width(160)
        Blank().layoutWeight(1)
        this.stick('右摇杆')
      }.width('100%').alignItems(VerticalAlign.Center).margin({ top: 16 })

      Button('菜单').height(40).width(116).borderRadius(12).fontSize(12)
        .backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF')
        .enabled(this.inputCapabilityReady && !this.editing)
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) { this.press('菜单'); }
          else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.release(); }
        }).margin({ top: 8 })
    }
    .width('92%').constraintSize({ maxWidth: 760 })
    .padding(18).backgroundColor('rgba(14,18,28,0.88)').borderRadius(20)
    .border({ width: 1, color: this.editing ? this.accentColor : 'rgba(255,255,255,0.16)' })
  }
}

export type MoonlightControllerSemanticElement =
  'faceA' | 'faceB' | 'faceX' | 'faceY' | 'dpad' | 'leftStick' |
  'rightStick' | 'leftTrigger' | 'rightTrigger' | 'leftShoulder' |
  'rightShoulder' | 'menu';
export type MoonlightControllerSemanticPhase = 'begin' | 'change' | 'end' | 'cancel';

export interface MoonlightControllerSemanticEvent {
  element: MoonlightControllerSemanticElement;
  phase: MoonlightControllerSemanticPhase;
  pointerId: number;
  primary: number;
  secondary: number;
}

@Component
export struct MoonlightControllerOverlay {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop inputCapabilityReady: boolean = false;
  @Prop editing: boolean = false;
  @Prop physicalControllerPathReady: boolean = false;
  @Prop physicalControllerName: string = '';
  @Prop physicalControllerSlot: number = -1;
  @State private activeButtons: string[] = [];
  @State private leftStickX: number = 0;
  @State private leftStickY: number = 0;
  @State private rightStickX: number = 0;
  @State private rightStickY: number = 0;
  private readonly activePointers: Map<string, number> = new Map<string, number>();
  onSemanticEvent: (event: MoonlightControllerSemanticEvent) => void =
    (_event: MoonlightControllerSemanticEvent): void => {};
  onClose: () => void = (): void => {};
  onEditToggle: () => void = (): void => {};

  private controllerPrimary(): string { return '#5B8FF9'; }

  private element(label: string): MoonlightControllerSemanticElement {
    if (label === 'A') { return 'faceA'; }
    if (label === 'B') { return 'faceB'; }
    if (label === 'X') { return 'faceX'; }
    if (label === 'Y') { return 'faceY'; }
    if (label === 'LT') { return 'leftTrigger'; }
    if (label === 'RT') { return 'rightTrigger'; }
    if (label === 'LB') { return 'leftShoulder'; }
    if (label === 'RB') { return 'rightShoulder'; }
    if (label === '菜单') { return 'menu'; }
    return 'dpad';
  }

  private pointerId(event: TouchEvent, fallback: number): number {
    const points = event.changedTouches.length > 0 ? event.changedTouches : event.touches;
    return points.length > 0 ? Math.max(1, Math.floor(points[0].id) + 1) : fallback;
  }

  private emit(label: string, phase: MoonlightControllerSemanticPhase,
    pointerId: number, primary: number = 0, secondary: number = 0): void {
    this.onSemanticEvent({
      element: this.element(label), phase: phase, pointerId: pointerId,
      primary: primary, secondary: secondary
    });
  }

  private press(label: string, event: TouchEvent): void {
    if (!this.inputCapabilityReady || this.editing) { return; }
    const id: number = this.pointerId(event, 100 + label.length);
    this.activePointers.set(label, id);
    if (this.activeButtons.indexOf(label) < 0) {
      this.activeButtons = this.activeButtons.concat([label]);
    }
    let primary: number = label === 'LT' || label === 'RT' ? 1 : 0;
    let secondary: number = 0;
    if (label === '上') { secondary = -1; }
    else if (label === '下') { secondary = 1; }
    else if (label === '左') { primary = -1; }
    else if (label === '右') { primary = 1; }
    this.emit(label, 'begin', id, primary, secondary);
  }

  private release(label: string, event: TouchEvent, cancelled: boolean): void {
    const pointer: number = this.activePointers.get(label) || this.pointerId(event, 100 + label.length);
    this.activePointers.delete(label);
    this.activeButtons = this.activeButtons.filter((value: string): boolean => value !== label);
    if (this.inputCapabilityReady && !this.editing) {
      this.emit(label, cancelled ? 'cancel' : 'end', pointer);
    }
  }

  private releaseAll(): void {
    this.activePointers.forEach((pointer: number, label: string): void => {
      if (this.inputCapabilityReady && !this.editing) {
        this.emit(label, 'cancel', pointer);
      }
    });
    this.activePointers.clear();
    this.activeButtons = [];
    this.leftStickX = 0; this.leftStickY = 0;
    this.rightStickX = 0; this.rightStickY = 0;
  }

  @Builder private faceButton(label: string, color: string) {
    Button(label).width(48).height(48).borderRadius(24).fontSize(14).fontWeight(FontWeight.Bold)
      .backgroundColor(this.activeButtons.indexOf(label) >= 0 ? color : 'rgba(255,255,255,0.12)')
      .fontColor('#FFFFFF').enabled(this.inputCapabilityReady && !this.editing)
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) { this.press(label, event); }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.release(label, event, event.type === TouchType.Cancel);
        }
      })
      .accessibilityText(label + ' 键')
  }

  private stickTouch(label: string, event: TouchEvent): void {
    if (!this.inputCapabilityReady || this.editing) { return; }
    const points = event.changedTouches.length > 0 ? event.changedTouches : event.touches;
    const pointer: number = this.pointerId(event, label === '左摇杆' ? 201 : 202);
    const element: MoonlightControllerSemanticElement =
      label === '左摇杆' ? 'leftStick' : 'rightStick';
    let phase: MoonlightControllerSemanticPhase = 'change';
    if (event.type === TouchType.Down) { phase = 'begin'; }
    else if (event.type === TouchType.Up) { phase = 'end'; }
    else if (event.type === TouchType.Cancel) { phase = 'cancel'; }
    let x: number = 0;
    let y: number = 0;
    if (phase === 'begin' || phase === 'change') {
      if (points.length === 0) { return; }
      x = Math.max(-1, Math.min(1, (points[0].x - 56) / 44));
      y = Math.max(-1, Math.min(1, (points[0].y - 56) / 44));
    }
    if (label === '左摇杆') { this.leftStickX = x; this.leftStickY = y; }
    else { this.rightStickX = x; this.rightStickY = y; }
    this.onSemanticEvent({ element: element, phase: phase, pointerId: pointer,
      primary: x, secondary: y });
  }

  @Builder private stick(label: string) {
    Stack({ alignContent: Alignment.Center }) {
      Column().width(104).height(104).borderRadius(52)
        .backgroundColor('rgba(255,255,255,0.08)')
        .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
      Column().width(54).height(54).borderRadius(27)
        .backgroundColor('rgba(255,255,255,0.22)')
        .translate({
          x: (label === '左摇杆' ? this.leftStickX : this.rightStickX) * 24,
          y: (label === '左摇杆' ? this.leftStickY : this.rightStickY) * 24
        })
      Text(label).fontSize(10).fontColor('rgba(255,255,255,0.64)')
    }.width(112).height(112).opacity(this.inputCapabilityReady && !this.editing ? 1 : 0.55)
      .onTouch((event: TouchEvent): void => { this.stickTouch(label, event); })
  }

  @Builder private dpadButton(label: string) {
    Button(label).width(34).height(34).borderRadius(9).fontSize(12).fontWeight(FontWeight.Bold)
      .backgroundColor(this.activeButtons.indexOf(label) >= 0 ? this.accentColor : 'rgba(255,255,255,0.12)')
      .fontColor('#FFFFFF').enabled(this.inputCapabilityReady && !this.editing)
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) { this.press(label, event); }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.release(label, event, event.type === TouchType.Cancel);
        }
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
          Text(this.physicalControllerName !== '' ?
            this.physicalControllerName + ' · 槽位 ' + (this.physicalControllerSlot + 1).toString() :
            (this.physicalControllerPathReady ?
              '实体手柄监听已就绪，接入后自动使用槽位 1' :
              '当前设备实体手柄监听不可用，虚拟控制器不受影响'))
            .fontSize(10).fontColor('rgba(255,255,255,0.60)').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.editing ? '完成布局' : '编辑布局').height(34).fontSize(11).borderRadius(10)
          .backgroundColor('rgba(255,255,255,0.10)').fontColor('#FFFFFF')
          .onClick((): void => { this.releaseAll(); this.onEditToggle(); })
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor(['#FFFFFF']) }
          .width(34).height(34).borderRadius(17).backgroundColor('rgba(255,255,255,0.10)')
          .margin({ left: 8 }).onClick((): void => { this.releaseAll(); this.onClose(); })
      }.width('100%')

      if (!this.inputCapabilityReady) {
        Row() {
          SymbolGlyph($r('sys.symbol.info_circle')).fontSize(16).fontColor(['#8FB5FF'])
          Text('控制器输入通道尚未就绪；在 native 接收能力可用前不会发送任何手柄信号。')
            .fontSize(10).fontColor('rgba(255,255,255,0.72)').layoutWeight(1).margin({ left: 8 })
        }.width('100%').padding(10).margin({ top: 12 })
          .backgroundColor('rgba(91,143,249,0.12)').borderRadius(10)
      }

      Row() {
        this.faceButton('LT', this.controllerPrimary())
        this.faceButton('LB', this.controllerPrimary())
        Blank().layoutWeight(1)
        Text('完整状态由 native 聚合').fontSize(9).fontColor('rgba(255,255,255,0.48)')
        Blank().layoutWeight(1)
        this.faceButton('RB', this.controllerPrimary())
        this.faceButton('RT', this.controllerPrimary())
      }.width('100%').margin({ top: 14 })

      Row() {
        Column({ space: 10 }) {
          this.dpad()
          this.stick('左摇杆')
        }
        Blank().layoutWeight(1)
        Column({ space: 8 }) {
          this.faceButton('Y', this.controllerPrimary())
          Row({ space: 48 }) {
            this.faceButton('X', this.controllerPrimary())
            this.faceButton('B', this.controllerPrimary())
          }
          this.faceButton('A', this.controllerPrimary())
        }.width(160)
        Blank().layoutWeight(1)
        this.stick('右摇杆')
      }.width('100%').alignItems(VerticalAlign.Center).margin({ top: 16 })

      Button('菜单').height(40).width(116).borderRadius(12).fontSize(12)
        .backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF')
        .enabled(this.inputCapabilityReady && !this.editing)
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) { this.press('菜单', event); }
          else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.release('菜单', event, event.type === TouchType.Cancel);
          }
        }).margin({ top: 8 })
    }
    .width('92%').constraintSize({ maxWidth: 760 })
    .padding(18).backgroundColor('rgba(14,18,28,0.88)').borderRadius(20)
    .border({ width: 1, color: this.editing ? this.accentColor : 'rgba(255,255,255,0.16)' })
  }
}

export enum ProtocolType {
  RDP = 'rdp',
  RUSTDESK = 'rustdesk'
}

@Component
export struct ProtocolSelector {
  @State selectedProtocol: ProtocolType = ProtocolType.RDP;
  @State showDropdown: boolean = false;
  onProtocolChange?: (protocol: ProtocolType) => void;

  private protocolOptions: Array<{ value: ProtocolType; label: string; desc: string }> = [
    { value: ProtocolType.RDP, label: 'RDP', desc: 'FreeRDP · 端口 3389 · 适合 Windows' },
    { value: ProtocolType.RUSTDESK, label: 'RustDesk', desc: '开源 · 端口 21116 · 跨平台穿透' }
  ];

  build() {
    Column() {
      Text('选择协议')
        .fontSize(15).fontColor('rgba(255,255,255,0.7)')
        .margin({ bottom: 12 })

      Row() {
        ForEach(this.protocolOptions, (option: { value: ProtocolType; label: string; desc: string }) => {
          Column() {
            Row() {
              Radio({ value: option.value, group: 'protocol' })
                .checked(this.selectedProtocol === option.value)
                .height(20).width(20)
                .onChange((isChecked: boolean) => {
                  if (isChecked) {
                    this.selectedProtocol = option.value;
                    this.onProtocolChange?.(option.value);
                  }
                })
              Text(option.label)
                .fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF').margin({ left: 8 })
            }
            .alignItems(VerticalAlign.Center)

            Text(option.desc)
              .fontSize(12).fontColor('rgba(255,255,255,0.5)')
              .margin({ left: 28, top: 4 })
          }
          .layoutWeight(1)
          .padding(16)
          .borderRadius(16)
          .backgroundColor(
            this.selectedProtocol === option.value
              ? 'rgba(102, 119, 255, 0.2)'
              : 'rgba(255,255,255,0.05)'
          )
          .border({
            width: 1,
            color: this.selectedProtocol === option.value
              ? '#6677ff'
              : 'rgba(255,255,255,0.1)',
            style: BorderStyle.Solid
          })
          .onClick(() => {
            this.selectedProtocol = option.value;
            this.onProtocolChange?.(option.value);
          })
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row() {
        Text('端口')
          .fontSize(14).fontColor('rgba(255,255,255,0.7)')
        Text(this.selectedProtocol === ProtocolType.RDP ? '3389' : '21116')
          .fontSize(14).fontColor('#6677ff')
          .margin({ left: 8 })
      }
      .margin({ top: 12 })
    }
    .width('100%')
  }
}

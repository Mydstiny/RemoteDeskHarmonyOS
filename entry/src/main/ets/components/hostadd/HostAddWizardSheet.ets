/** Modern add-host wizard shell. Protocol-specific steps are injected by the host page. */
import { HostProtocolPicker } from './HostProtocolPicker';

@Component
export struct HostAddWizardSheet {
  @Prop moonlightProtocolAvailable: boolean = true;
  onSelectProtocol: (protocol: string) => void = (_protocol: string): void => {};
  onClose: () => void = (): void => {};

  build() {
    HostProtocolPicker({
      moonlightProtocolAvailable: this.moonlightProtocolAvailable,
      onSelect: (protocol: string): void => { this.onSelectProtocol(protocol); },
      onClose: (): void => { this.onClose(); }
    })
  }
}

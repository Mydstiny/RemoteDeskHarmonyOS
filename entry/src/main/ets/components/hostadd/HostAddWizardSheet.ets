/** Modern add-host wizard shell. Protocol-specific steps are injected by the host page. */
import { HostProtocolPicker } from './HostProtocolPicker';

@Component
export struct HostAddWizardSheet {
  @Prop moonlightFabEntryAvailable: boolean = false;
  @Prop moonlightProtocolAvailable: boolean = false;
  onSelectProtocol: (protocol: string) => void = (_protocol: string): void => {};
  onClose: () => void = (): void => {};

  build() {
    HostProtocolPicker({
      moonlightFabEntryAvailable: this.moonlightFabEntryAvailable,
      moonlightProtocolAvailable: this.moonlightProtocolAvailable,
      onSelect: (protocol: string): void => { this.onSelectProtocol(protocol); },
      onClose: (): void => { this.onClose(); }
    })
  }
}

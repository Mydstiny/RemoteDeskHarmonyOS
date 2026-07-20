/** HostAddDraft — state owned by the modern add-host wizard until final save. */
import { RemoteHost } from './RemoteHost';

export class HostAddDraft {
  step: number = 0;
  protocol: string = '';
  label: string = '';
  host: string = '';
  port: number = 0;
  username: string = '';
  password: string = '';
  credentialId: string = '';
  sshUseKey: boolean = false;
  sshKeyId: string = '';
  rustdeskDirectEnabled: boolean = false;
  rustdeskDirectHost: string = '';
  rustdeskDirectPort: number = 21118;
  rustdeskRelayId: string = '';
  rustdeskPasswordMode: number = 1;
  rustdeskAuthMode: string = 'password';
  controlId: string = '';

  selectProtocol(protocol: string): void {
    this.protocol = protocol;
    this.port = RemoteHost.getDefaultPort(protocol);
    this.step = 1;
  }

  nextStep(): void {
    this.step += 1;
  }

  previousStep(): void {
    if (this.step > 0) { this.step -= 1; }
  }

  reset(): void {
    this.step = 0;
    this.protocol = '';
    this.label = '';
    this.host = '';
    this.port = 0;
    this.username = '';
    this.password = '';
    this.credentialId = '';
    this.sshUseKey = false;
    this.sshKeyId = '';
    this.rustdeskDirectEnabled = false;
    this.rustdeskDirectHost = '';
    this.rustdeskDirectPort = 21118;
    this.rustdeskRelayId = '';
    this.rustdeskPasswordMode = 1;
    this.rustdeskAuthMode = 'password';
    this.controlId = '';
  }

  validateCurrentStep(): string {
    if (this.protocol === '') { return '请选择连接协议'; }
    if (this.step >= 1 && this.label.trim() === '') { return '请输入主机名称'; }
    if (this.step >= 1 && this.protocol !== 'rustdesk' && this.host.trim() === '') {
      return '请输入主机地址';
    }
    if (this.step >= 1 && this.protocol !== 'rustdesk' && (this.port <= 0 || this.port > 65535)) {
      return '端口必须在 1-65535 之间';
    }
    return '';
  }

  toRemoteHost(): RemoteHost {
    const host = new RemoteHost();
    host.id = RemoteHost.generateId();
    host.protocol = this.protocol;
    host.label = this.label.trim();
    host.host = this.host.trim();
    host.port = this.port;
    host.username = this.username.trim();
    host.password = this.password;
    host.rdpCredentialId = this.credentialId;
    host.sshUseKey = this.sshUseKey;
    host.sshKeyId = this.sshKeyId;
    host.rustdeskDirectEnabled = this.rustdeskDirectEnabled;
    host.rustdeskDirectHost = this.rustdeskDirectHost.trim();
    host.rustdeskDirectPort = this.rustdeskDirectPort;
    host.rustdeskRelayId = this.rustdeskRelayId;
    host.rustdeskPasswordMode = this.rustdeskPasswordMode;
    host.rustdeskAuthMode = this.rustdeskDirectEnabled ? 'password' : this.rustdeskAuthMode;
    host.customHostname = this.controlId.trim();
    if (this.protocol === 'rustdesk' && this.rustdeskDirectEnabled) {
      host.host = host.rustdeskDirectHost;
      host.port = host.rustdeskDirectPort;
    }
    return host;
  }
}

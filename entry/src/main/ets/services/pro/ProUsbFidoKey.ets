import { usbManager, BusinessError } from '@kit.BasicServicesKit';
import { isProFidoReportDescriptor, PRO_FIDO_PACKET_SIZE } from './ProFidoHidCodec';

export interface ProUsbFidoKeyCandidate { key: string; label: string; }

interface ProUsbFidoKeyEndpoint {
  candidate: ProUsbFidoKeyCandidate;
  device: usbManager.USBDevice;
  config: usbManager.USBConfiguration;
  iface: usbManager.USBInterface;
  input: number;
  output: number;
}

function keyLabel(device: usbManager.USBDevice): string {
  const text = (device.manufacturerName + ' ' + device.productName)
    .replace(/[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/g, '').trim().slice(0, 80);
  return text || ('USB 安全密钥 ' + device.vendorId.toString(16).padStart(4, '0') + ':' +
    device.productId.toString(16).padStart(4, '0'));
}

/**
 * One authorized FIDO HID interface: the only device an RDP session's security-key broker reaches.
 * Every transfer is a single 64-byte interrupt report; release cancels the transfer in flight.
 */
export class ProUsbFidoKeySession {
  readonly label: string;
  private pipe: usbManager.USBDevicePipe | null;
  private iface: usbManager.USBInterface;
  private input: number;
  private output: number;
  private inFlight: usbManager.UsbDataTransferParams | null = null;

  constructor(label: string, pipe: usbManager.USBDevicePipe, iface: usbManager.USBInterface, input: number,
    output: number) {
    this.label = label;
    this.pipe = pipe;
    this.iface = iface;
    this.input = input;
    this.output = output;
  }

  get open(): boolean { return this.pipe !== null; }

  /** Resolves with the 64 transferred bytes, or null on any failure, timeout or release. */
  transfer(write: boolean, data: Uint8Array, timeoutMs: number): Promise<Uint8Array | null> {
    const pipe = this.pipe;
    if (pipe === null || data.length !== PRO_FIDO_PACKET_SIZE || this.inFlight !== null) {
      return Promise.resolve(null);
    }
    const buffer = new Uint8Array(PRO_FIDO_PACKET_SIZE);
    if (write) { buffer.set(data); }
    const timeout = Math.max(1, Math.min(Math.round(timeoutMs), 5000));
    return new Promise<Uint8Array | null>((resolve: (value: Uint8Array | null) => void): void => {
      let settled: boolean = false;
      const finish = (value: Uint8Array | null): void => {
        if (settled) { return; }
        settled = true;
        if (this.inFlight === request) { this.inFlight = null; }
        resolve(value);
      };
      const request: usbManager.UsbDataTransferParams = {
        devPipe: pipe, flags: usbManager.UsbTransferFlags.USB_TRANSFER_SHORT_NOT_OK,
        endpoint: write ? this.output : this.input, type: usbManager.UsbEndpointTransferType.TRANSFER_TYPE_INTERRUPT,
        timeout, length: buffer.length, userData: new Uint8Array(0), buffer, isoPacketCount: 0,
        callback: (error: BusinessError, result: usbManager.SubmitTransferCallback): void => {
          finish(error || !result || result.status !== usbManager.UsbTransferStatus.TRANSFER_COMPLETED ||
            result.actualLength !== buffer.length ? null : buffer);
        }
      };
      this.inFlight = request;
      // The USB stack's own timeout normally fires first; this only guards a lost callback.
      setTimeout((): void => {
        if (!settled) {
          try { usbManager.usbCancelTransfer(request); } catch (_error) {}
          finish(null);
        }
      }, timeout + 1000);
      try { usbManager.usbSubmitTransfer(request); } catch (_error) { finish(null); }
    });
  }

  release(): void {
    const pipe = this.pipe;
    this.pipe = null;
    const transfer = this.inFlight;
    this.inFlight = null;
    if (transfer !== null) { try { usbManager.usbCancelTransfer(transfer); } catch (_error) {} }
    if (pipe !== null) {
      try { usbManager.releaseInterface(pipe, this.iface); } catch (_error) {}
      try { usbManager.closePipe(pipe); } catch (_error) {}
    }
  }
}

/** Lists FIDO HID interfaces and authorizes one; never touches keyboards, mice or other HID devices. */
export class ProUsbFidoKeys {
  private candidates: ProUsbFidoKeyEndpoint[] = [];
  private generation: number = 0;

  list(): ProUsbFidoKeyCandidate[] {
    this.candidates = [];
    const generation = ++this.generation;
    try {
      const devices = usbManager.getDevices();
      if (devices.length > 64) { return []; }
      devices.forEach((device: usbManager.USBDevice): void => {
        if (device.configs.length > 16) { return; }
        device.configs.forEach((config: usbManager.USBConfiguration): void => {
          if (config.interfaces.length > 64) { return; }
          config.interfaces.forEach((iface: usbManager.USBInterface): void => {
            if (this.candidates.length >= 16 || iface.clazz !== 3 || iface.subClass !== 0 || iface.protocol !== 0 ||
                iface.alternateSetting !== 0 || iface.endpoints.length !== 2) { return; }
            const inputs = iface.endpoints.filter((endpoint: usbManager.USBEndpoint): boolean =>
              endpoint.interfaceId === iface.id && endpoint.type === 3 && (endpoint.attributes & 3) === 3 &&
              endpoint.maxPacketSize === PRO_FIDO_PACKET_SIZE && endpoint.address > 0x80 && endpoint.address <= 0x8f &&
              endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE);
            const outputs = iface.endpoints.filter((endpoint: usbManager.USBEndpoint): boolean =>
              endpoint.interfaceId === iface.id && endpoint.type === 3 && (endpoint.attributes & 3) === 3 &&
              endpoint.maxPacketSize === PRO_FIDO_PACKET_SIZE && endpoint.address > 0 && endpoint.address <= 0x0f &&
              endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE);
            if (inputs.length !== 1 || outputs.length !== 1) { return; }
            const candidate: ProUsbFidoKeyCandidate = {
              key: generation.toString() + ':' + this.candidates.length.toString(), label: keyLabel(device) };
            this.candidates.push({ candidate, device, config, iface, input: inputs[0].address, output: outputs[0].address });
          });
        });
      });
    } catch (_error) { this.candidates = []; }
    return this.candidates.map((entry: ProUsbFidoKeyEndpoint): ProUsbFidoKeyCandidate =>
      ({ key: entry.candidate.key, label: entry.candidate.label }));
  }

  /**
   * Asks the system for temporary access, re-checks that the same interface is still present, verifies the
   * active configuration and the FIDO report descriptor, then claims the interface without forcing it.
   * Throws an Error whose message is shown to the user.
   */
  async authorize(key: string, isCurrent: () => boolean): Promise<ProUsbFidoKeySession> {
    const selected = this.candidates.find((item: ProUsbFidoKeyEndpoint): boolean => item.candidate.key === key);
    if (selected === undefined) { throw new Error('请重新选择安全密钥'); }
    let granted: boolean = false;
    try { granted = await usbManager.requestRight(selected.device.name); }
    catch (_error) { throw new Error('无法请求 USB 访问授权'); }
    if (!isCurrent()) { throw new Error('安全密钥请求已结束'); }
    if (!granted) { throw new Error('未获得 USB 访问授权'); }
    let devices: usbManager.USBDevice[] = [];
    try { devices = usbManager.getDevices(); }
    catch (_error) { throw new Error('无法读取 USB 设备'); }
    const present = devices.find((device: usbManager.USBDevice): boolean =>
      device.name === selected.device.name && device.busNum === selected.device.busNum &&
      device.devAddress === selected.device.devAddress && device.vendorId === selected.device.vendorId &&
      device.productId === selected.device.productId);
    if (present === undefined) { throw new Error('安全密钥已拔出，请重新插入后再选'); }
    const presentInterface = present.configs.find((item: usbManager.USBConfiguration): boolean =>
      item.id === selected.config.id)?.interfaces.find((item: usbManager.USBInterface): boolean =>
      item.id === selected.iface.id && item.alternateSetting === selected.iface.alternateSetting);
    if (presentInterface === undefined || presentInterface.clazz !== 3 ||
        presentInterface.endpoints.length !== selected.iface.endpoints.length) {
      throw new Error('安全密钥接口已变化，请重新选择');
    }
    let pipe: usbManager.USBDevicePipe | null = null;
    try { pipe = usbManager.connectDevice(present); }
    catch (_error) { pipe = null; }
    if (!pipe) { throw new Error('安全密钥暂不可用'); }
    let claimed: boolean = false;
    try {
      const config = new Uint8Array(1);
      const configCount: number = await usbManager.usbControlTransfer(pipe,
        { bmRequestType: 0x80, bRequest: 8, wValue: 0, wIndex: 0, wLength: 1, data: config }, 1500);
      if (configCount !== 1 || config[0] !== selected.config.id) { throw new Error('所选接口不属于当前 USB 配置'); }
      const descriptor = new Uint8Array(4096);
      const descriptorCount: number = await usbManager.usbControlTransfer(pipe,
        { bmRequestType: 0x81, bRequest: 6, wValue: 0x2200, wIndex: selected.iface.id,
          wLength: descriptor.length, data: descriptor }, 1500);
      if (!Number.isInteger(descriptorCount) || descriptorCount < 16 || descriptorCount > descriptor.length ||
          !isProFidoReportDescriptor(descriptor.subarray(0, descriptorCount))) {
        throw new Error('这个设备不是受支持的 FIDO 安全密钥');
      }
      if (usbManager.claimInterface(pipe, selected.iface, false) !== 0) {
        throw new Error('安全密钥正被其他应用使用');
      }
      claimed = true;
      if (!isCurrent()) { throw new Error('安全密钥请求已结束'); }
      return new ProUsbFidoKeySession(selected.candidate.label, pipe, selected.iface, selected.input, selected.output);
    } catch (error) {
      if (claimed) { try { usbManager.releaseInterface(pipe, selected.iface); } catch (_error) {} }
      try { usbManager.closePipe(pipe); } catch (_error) {}
      throw error instanceof Error ? error : new Error('无法连接安全密钥');
    }
  }
}

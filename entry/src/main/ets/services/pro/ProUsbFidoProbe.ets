import { DEBUG } from 'BuildProfile';
import { usbManager, deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ProAppRuntime } from './ProAppRuntime';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { isProFidoReportDescriptor, parseProFidoInit, proFidoPackets, ProFidoHidResponse,
  PRO_FIDO_BROADCAST, PRO_FIDO_INIT, PRO_FIDO_PACKET_SIZE } from './ProFidoHidCodec';

export interface ProUsbFidoCandidate { key: string; label: string; }
interface ProUsbFidoEndpoint {
  candidate: ProUsbFidoCandidate;
  device: usbManager.USBDevice;
  config: usbManager.USBConfiguration;
  iface: usbManager.USBInterface;
  input: number;
  output: number;
}
class ProUsbProbeOperation {
  cancelled: boolean = false;
  failure: string = '';
  deadline: number = Date.now() + 120000;
  current: () => boolean;
  pipe: usbManager.USBDevicePipe | null = null;
  iface: usbManager.USBInterface | null = null;
  transfer: usbManager.UsbDataTransferParams | null = null;
  waits: Array<() => void> = [];
  constructor(current: () => boolean) { this.current = current; }
}

/** Hardware feasibility probe, not a WebAuthn authenticator or an RDP channel. */
export class ProUsbFidoProbe {
  private static instance: ProUsbFidoProbe = new ProUsbFidoProbe();
  private candidates: ProUsbFidoEndpoint[] = [];
  private selectionGeneration: number = 0;
  private active: ProUsbProbeOperation | null = null;
  private transitionActive: boolean = true;
  private constructor() {
    if (DEBUG) {
      AccountSessionCoordinator.getInstance().onTransitionActivity((active: boolean): void => {
        this.transitionActive = active;
        if (active && this.active !== null) { this.stop(this.active, '账号正在切换，USB 检测已取消'); }
      });
    }
  }
  static getInstance(): ProUsbFidoProbe { return ProUsbFidoProbe.instance; }

  debugAllowed(): boolean {
    // The entire granting branch is removed from the actual Release bytecode.
    if (DEBUG) {
      return !this.transitionActive && deviceInfo.sdkApiVersion >= 23 && ['pc', '2in1'].indexOf(deviceInfo.deviceType) >= 0 &&
        canIUse('SystemCapability.USB.USBManager') && ProAppRuntime.getInstance().runtime.snapshot().mode === 'pro';
    }
    return false;
  }
  busy(): boolean { return this.active !== null; }
  private label(device: usbManager.USBDevice, iface: usbManager.USBInterface): string {
    const text = (device.manufacturerName + ' ' + device.productName)
      .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, '').trim().slice(0, 80);
    return (text || 'USB HID') + ' · ' + device.vendorId.toString(16).padStart(4, '0') + ':' +
      device.productId.toString(16).padStart(4, '0') + ' · 接口 ' + iface.id.toString();
  }
  list(): ProUsbFidoCandidate[] {
    if (!this.debugAllowed() || this.busy()) { return []; }
    this.candidates = []; const generation = ++this.selectionGeneration;
    try {
      const devices = usbManager.getDevices();
      if (devices.length > 64) { return []; }
      devices.forEach((device: usbManager.USBDevice): void => {
        if (device.configs.length > 16) { return; }
        device.configs.forEach((config: usbManager.USBConfiguration): void => {
          if (config.interfaces.length > 64) { return; }
          config.interfaces.forEach((iface: usbManager.USBInterface): void => {
            if (this.candidates.length >= 32 || iface.clazz !== 3 || iface.subClass !== 0 || iface.protocol !== 0 ||
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
            const candidate: ProUsbFidoCandidate = { key: generation.toString() + ':' + this.candidates.length.toString(),
              label: this.label(device, iface) };
            this.candidates.push({ candidate, device, config, iface, input: inputs[0].address, output: outputs[0].address });
          });
        });
      });
    } catch (_error) { this.candidates = []; }
    return this.candidates.map((entry: ProUsbFidoEndpoint): ProUsbFidoCandidate =>
      ({ key: entry.candidate.key, label: entry.candidate.label }));
  }
  cancel(owner: () => boolean): void {
    if (this.active !== null && this.active.current === owner) { this.stop(this.active, '已取消 USB 检测'); }
  }
  private stop(operation: ProUsbProbeOperation, message: string): void {
    if (operation.cancelled) { return; }
    operation.cancelled = true; operation.failure = message;
    const transfer = operation.transfer;
    if (transfer !== null) { try { usbManager.usbCancelTransfer(transfer); } catch (_error) {} }
    operation.waits.slice().forEach((cancel: () => void): void => { cancel(); });
  }
  private valid(operation: ProUsbProbeOperation): boolean {
    try {
      return this.active === operation && !operation.cancelled && this.debugAllowed() &&
        Date.now() < operation.deadline && operation.current();
    } catch (_error) { return false; }
  }
  private requireCurrent(operation: ProUsbProbeOperation): void {
    if (!this.valid(operation)) {
      this.stop(operation, Date.now() >= operation.deadline ? 'USB 检测超时' : 'USB 检测已失效');
      throw new Error(operation.failure);
    }
  }
  private wait<T>(operation: ProUsbProbeOperation, promise: Promise<T>, timeout: number): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void): void => {
      let settled: boolean = false;
      let timer: number = -1;
      const cleanup = (): void => {
        if (timer !== -1) { clearTimeout(timer); }
        operation.waits = operation.waits.filter((item: () => void): boolean => item !== cancel);
      };
      const cancel = (): void => {
        if (settled) { return; } settled = true; cleanup(); reject(new Error(operation.failure || 'USB 检测已取消'));
      };
      operation.waits.push(cancel);
      timer = setTimeout((): void => { this.stop(operation, 'USB 检测超时'); }, timeout);
      promise.then((value: T): void => {
        if (settled) { return; } settled = true; cleanup(); resolve(value);
      }, (_error: Object): void => {
        if (settled) { return; } settled = true; cleanup(); reject(new Error('USB 通信失败'));
      });
      if (operation.cancelled) { cancel(); }
    });
  }
  private async transfer(operation: ProUsbProbeOperation, endpoint: number, data: Uint8Array): Promise<Uint8Array> {
    this.requireCurrent(operation);
    const pipe = operation.pipe;
    if (pipe === null) { throw new Error('USB 设备未连接'); }
    const pending = new Promise<Uint8Array>((resolve: (value: Uint8Array) => void, reject: (reason: Error) => void): void => {
      const request: usbManager.UsbDataTransferParams = { devPipe: pipe,
        flags: usbManager.UsbTransferFlags.USB_TRANSFER_SHORT_NOT_OK,
        endpoint, type: usbManager.UsbEndpointTransferType.TRANSFER_TYPE_INTERRUPT,
        timeout: 1500, length: data.length, userData: new Uint8Array(0), buffer: data, isoPacketCount: 0,
        callback: (error: BusinessError, result: usbManager.SubmitTransferCallback): void => {
          if (operation.transfer === request) { operation.transfer = null; }
          if (error || !result || result.status !== usbManager.UsbTransferStatus.TRANSFER_COMPLETED ||
              result.actualLength !== data.length) { reject(new Error('USB 中断传输失败')); return; }
          resolve(data);
        }
      };
      operation.transfer = request;
      try { usbManager.usbSubmitTransfer(request); }
      catch (_error) { operation.transfer = null; reject(new Error('无法提交 USB 中断传输')); }
    });
    const result = await this.wait(operation, pending, 2200);
    this.requireCurrent(operation);
    return result;
  }
  async probe(key: string, isCurrent: () => boolean): Promise<string> {
    if (!this.debugAllowed() || this.busy() || !isCurrent()) { throw new Error('USB 检测当前不可用'); }
    const selected = this.candidates.find((item: ProUsbFidoEndpoint): boolean => item.candidate.key === key);
    if (selected === undefined) { throw new Error('请重新读取 USB 设备'); }
    const operation = new ProUsbProbeOperation(isCurrent); this.active = operation;
    let initialized: boolean = false;
    const unsubscribe = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      if (initialized) { this.stop(operation, '账号或调试状态已变化，USB 检测已取消'); }
    });
    initialized = true;
    const watcher = setInterval((): void => {
      if (!this.valid(operation)) { this.stop(operation, 'USB 检测已取消或超时'); }
    }, 100);
    try {
      const granted = await this.wait(operation, usbManager.requestRight(selected.device.name), 120000);
      this.requireCurrent(operation);
      if (!granted) { operation.failure = '未获得 USB 临时访问授权'; throw new Error(operation.failure); }
      operation.deadline = Date.now() + 8000;
      const present = usbManager.getDevices().find((device: usbManager.USBDevice): boolean =>
        device.name === selected.device.name && device.busNum === selected.device.busNum &&
        device.devAddress === selected.device.devAddress && device.vendorId === selected.device.vendorId &&
        device.productId === selected.device.productId);
      if (present === undefined) { operation.failure = '所选 USB 设备已拔出或变化'; throw new Error(operation.failure); }
      const presentConfig = present.configs.find((item: usbManager.USBConfiguration): boolean => item.id === selected.config.id);
      const presentInterface = presentConfig?.interfaces.find((item: usbManager.USBInterface): boolean =>
        item.id === selected.iface.id && item.alternateSetting === selected.iface.alternateSetting);
      if (presentInterface === undefined || presentInterface.clazz !== selected.iface.clazz ||
          presentInterface.subClass !== selected.iface.subClass || presentInterface.protocol !== selected.iface.protocol ||
          presentInterface.endpoints.length !== selected.iface.endpoints.length ||
          presentInterface.endpoints.some((endpoint: usbManager.USBEndpoint): boolean =>
            !selected.iface.endpoints.some((old: usbManager.USBEndpoint): boolean =>
              old.address === endpoint.address && old.interfaceId === endpoint.interfaceId && old.type === endpoint.type &&
              old.maxPacketSize === endpoint.maxPacketSize && old.direction === endpoint.direction && old.attributes === endpoint.attributes))) {
        operation.failure = 'USB 接口在授权期间已变化，请重新读取设备'; throw new Error(operation.failure);
      }
      this.requireCurrent(operation);
      const pipe = usbManager.connectDevice(present);
      if (!pipe) { throw new Error('USB 设备暂不可用'); }
      operation.pipe = pipe;
      const config = new Uint8Array(1);
      const configCount = await this.wait(operation, usbManager.usbControlTransfer(pipe,
        { bmRequestType: 0x80, bRequest: 8, wValue: 0, wIndex: 0, wLength: 1, data: config }, 1500), 2200);
      this.requireCurrent(operation);
      if (configCount !== 1 || config[0] !== selected.config.id) {
        operation.failure = '所选 USB 接口不属于当前配置'; throw new Error(operation.failure);
      }
      const descriptor = new Uint8Array(4096);
      const descriptorCount = await this.wait(operation, usbManager.usbControlTransfer(pipe,
        { bmRequestType: 0x81, bRequest: 6, wValue: 0x2200, wIndex: selected.iface.id,
          wLength: descriptor.length, data: descriptor }, 1500), 2200);
      this.requireCurrent(operation);
      if (!Number.isInteger(descriptorCount) || descriptorCount < 16 || descriptorCount > descriptor.length ||
          !isProFidoReportDescriptor(descriptor.subarray(0, descriptorCount))) {
        operation.failure = '此接口不是当前支持的 FIDO HID 报告格式'; throw new Error(operation.failure);
      }
      if (usbManager.claimInterface(pipe, selected.iface, false) !== 0) {
        operation.failure = '安全密钥接口正被占用或不可访问'; throw new Error(operation.failure);
      }
      operation.iface = selected.iface;
      const nonce = cryptoFramework.createRandom().generateRandomSync(8).data;
      const request = proFidoPackets(PRO_FIDO_BROADCAST, PRO_FIDO_INIT, nonce);
      await this.transfer(operation, selected.output, request[0]);
      const response = new ProFidoHidResponse(PRO_FIDO_BROADCAST, PRO_FIDO_INIT);
      for (let reports: number = 0; reports < 160; reports++) {
        const packet = await this.transfer(operation, selected.input, new Uint8Array(PRO_FIDO_PACKET_SIZE));
        const data = response.accept(packet);
        if (data === null) { continue; }
        const info = parseProFidoInit(data, nonce);
        this.requireCurrent(operation);
        return info.cbor ? 'FIDO2 USB 初始化成功。RDP 注册与认证尚待接入及真机验收。' :
          'USB 初始化成功，但此设备未声明 FIDO2 CBOR 支持。';
      }
      operation.failure = '未收到匹配的安全密钥初始化响应'; throw new Error(operation.failure);
    } catch (_error) {
      throw new Error(operation.failure || 'USB 检测失败，请确认设备支持并重试');
    } finally {
      this.stop(operation, operation.failure || 'USB 检测已结束');
      clearInterval(watcher); unsubscribe();
      const pipe = operation.pipe;
      if (pipe !== null) {
        if (operation.iface !== null) { try { usbManager.releaseInterface(pipe, operation.iface); } catch (_error) {} }
        try { usbManager.closePipe(pipe); } catch (_error) {}
      }
      operation.pipe = null; operation.iface = null;
      if (this.active === operation) { this.active = null; }
    }
  }
}

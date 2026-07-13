/**
 * LightSensingService.ets — 环境光传感器服务
 * 接入真实传感器，提供动态光效强度调节
 */
import { sensor } from '@kit.SensorServiceKit';

interface LightListener {
  callback: (lux: number) => void;
}

export class LightSensingService {
  private static instance: LightSensingService;
  private currentLux: number = 200;
  private isMonitoring: boolean = false;
  private listeners: LightListener[] = [];

  static getInstance(): LightSensingService {
    if (!LightSensingService.instance) {
      LightSensingService.instance = new LightSensingService();
    }
    return LightSensingService.instance;
  }

  /**
   * 启动环境光监测（每秒采样）
   */
  startMonitoring(): void {
    if (this.isMonitoring) {
      return;
    }
    try {
      sensor.on(
        sensor.SensorId.AMBIENT_LIGHT,
        (data: Object): void => {
          const light = (data as Record<string, number>)['light'];
          if (typeof light === 'number') {
            this.currentLux = light;
            this.notifyListeners(light);
          }
        },
        { interval: 1000000000 } // 1秒
      );
      this.isMonitoring = true;
    } catch (err) {
      console.warn('环境光传感器不可用，使用默认光效强度');
    }
  }

  stopMonitoring(): void {
    if (!this.isMonitoring) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.AMBIENT_LIGHT);
    } catch (err) {
      // 忽略
    }
    this.isMonitoring = false;
  }

  /**
   * 获取建议的光效强度 (0.0 ~ 1.0)
   */
  getLightIntensity(): number {
    if (this.currentLux < 50) {
      return 0.85;
    }
    if (this.currentLux < 200) {
      return 0.70;
    }
    if (this.currentLux < 500) {
      return 0.50;
    }
    return 0.30;
  }

  /**
   * 获取建议的主题模式
   */
  getRecommendedTheme(): string {
    return this.currentLux < 300 ? 'dark' : 'light';
  }

  /**
   * 获取当前照度值
   */
  getCurrentLux(): number {
    return this.currentLux;
  }

  /**
   * 注册光感变化监听
   */
  onLightChange(callback: (lux: number) => void): void {
    this.listeners.push({ callback: callback });
  }

  /**
   * 注销监听
   */
  offLightChange(callback: (lux: number) => void): void {
    const filtered: LightListener[] = [];
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.listeners[i].callback !== callback) {
        filtered.push(this.listeners[i]);
      }
    }
    this.listeners = filtered;
  }

  private notifyListeners(lux: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].callback(lux);
    }
  }
}

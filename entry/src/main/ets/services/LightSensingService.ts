import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class LightSensingService {
  private static instance: LightSensingService;
  private currentLux: number = 200;
  private listeners: Array<(lux: number) => void> = [];
  private monitoring: boolean = false;

  static getInstance(): LightSensingService {
    if (!this.instance) {
      this.instance = new LightSensingService();
    }
    return this.instance;
  }

  startMonitoring(): void {
    if (this.monitoring) return;
    try {
      sensor.on(
        sensor.SensorId.AMBIENT_LIGHT,
        (data: sensor.AmbientLightResponse) => {
          this.currentLux = data.light;
          this.notifyListeners(data.light);
        },
        { interval: 1000000000 }
      );
      this.monitoring = true;
      console.info('LightSensingService monitoring started');
    } catch (err) {
      console.warn('Ambient light sensor not available, theme will remain static');
    }
  }

  stopMonitoring(): void {
    try {
      sensor.off(sensor.SensorId.AMBIENT_LIGHT);
      this.monitoring = false;
      console.info('LightSensingService monitoring stopped');
    } catch (err) {
      console.error('Failed to stop light sensor: ' + err);
    }
  }

  getLightIntensity(): number {
    if (this.currentLux < 50) return 0.85;
    if (this.currentLux < 200) return 0.70;
    if (this.currentLux < 500) return 0.50;
    return 0.30;
  }

  getRecommendedTheme(): 'dark' | 'light' {
    return this.currentLux < 300 ? 'dark' : 'light';
  }

  getCurrentLux(): number {
    return this.currentLux;
  }

  onLightChange(callback: (lux: number) => void): void {
    this.listeners.push(callback);
  }

  removeListener(callback: (lux: number) => void): void {
    const idx = this.listeners.indexOf(callback);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notifyListeners(lux: number): void {
    for (const cb of this.listeners) {
      cb(lux);
    }
  }
}

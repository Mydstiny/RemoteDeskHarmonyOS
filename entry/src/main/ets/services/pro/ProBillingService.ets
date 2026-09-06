import { runCurrentProPurchase } from './ProPurchaseLifecycle';
import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const PRO_LAUNCH_PRICE: string = '¥19.99';
export const PRO_REGULAR_PRICE: string = '¥28.88';
export interface ProStoreProduct { id: string; name: string; price: string; }
export interface ProBillingProvider {
  product(context: common.UIAbilityContext, id: string): Promise<ProStoreProduct>;
  purchase(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<void>;
  restore(context: common.UIAbilityContext): Promise<number>;
}

export function proBillingError(error: BusinessError): string {
  if (error.code === 1001860000) { return '已取消购买，你可以稍后再试。'; }
  if (error.code === 1001860057) { return '请安装配置正确的 debug 测试包。'; }
  if (error.code === 1001860058) { return '请在设备上登录已加入 AGC 沙盒名单的华为账号。'; }
  if (error.code === 1001860051) { return '已拥有该商品，请使用恢复购买检查订单。'; }
  if (error.code === 1001860005) { return '网络连接失败，请稍后重试。'; }
  if (error.code === 801) { return '当前设备暂不支持这项支付能力。'; }
  return '未能完成操作，请检查沙盒、商品与签名配置。';
}

export class HuaweiProBillingProvider implements ProBillingProvider {
  private async sandbox(context: common.UIAbilityContext): Promise<void> {
    if (!await iap.isSandboxActivated(context)) { throw new Error('Sandbox required'); }
  }
  async product(context: common.UIAbilityContext, id: string): Promise<ProStoreProduct> {
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(id)) { throw new Error('Invalid product ID'); }
    await this.sandbox(context);
    const products = await iap.queryProducts(context, { productType: iap.ProductType.NONCONSUMABLE, productIds: [id] });
    const product = products.find((item: iap.Product): boolean => item.id === id && item.type === iap.ProductType.NONCONSUMABLE);
    if (!product || !product.localPrice) { throw new Error('Product unavailable'); }
    return { id: product.id, name: product.name, price: product.localPrice };
  }
  async purchase(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<void> {
    await runCurrentProPurchase((): Promise<void> => this.sandbox(context), isCurrent, async (): Promise<void> => {
      // No grant or delivery acknowledgement without a trusted verifier.
      await iap.createPurchase(context, { productType: iap.ProductType.NONCONSUMABLE, productId: id });
    });
  }
  async restore(context: common.UIAbilityContext): Promise<number> {
    await this.sandbox(context);
    let total: number = 0;
    const types: iap.PurchaseQueryType[] = [iap.PurchaseQueryType.CURRENT_ENTITLEMENT, iap.PurchaseQueryType.UNFINISHED];
    for (const queryType of types) {
      let cursor: string | undefined = undefined;
      const seen: string[] = [];
      do {
        const result: iap.QueryPurchaseResult = await iap.queryPurchases(context, {
          productType: iap.ProductType.NONCONSUMABLE, queryType: queryType, continuationToken: cursor
        });
        total += result.purchaseDataList.length;
        cursor = result.continuationToken;
        if (cursor) {
          if (seen.indexOf(cursor) >= 0 || seen.length >= 100) { throw new Error('Invalid pagination'); }
          seen.push(cursor);
        }
      } while (cursor);
    }
    return total;
  }
}

// Process-wide admission survives sheet dismissal/reopening. It never stores order payloads.
export class ProPurchaseCoordinator {
  private static running: boolean = false;
  static enter(): boolean {
    if (ProPurchaseCoordinator.running) { return false; }
    ProPurchaseCoordinator.running = true;
    return true;
  }
  static leave(): void { ProPurchaseCoordinator.running = false; }
}

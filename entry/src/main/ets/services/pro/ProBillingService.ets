import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { DEBUG } from 'BuildProfile';
import { ProClientLease, ProPurchaseIntent, proPurchaseBatches } from './ProTrustedEntitlementClient';
import { ProReconciliationOutcome } from './ProEntitlementService';

export const PRO_LAUNCH_PRICE: string = '¥19.99';
export const PRO_REGULAR_PRICE: string = '¥28.88';
export interface ProStoreProduct { id: string; name: string; price: string; }
export interface ProBillingOutcome { verified: boolean; records: number; }
export interface ProBillingBackend {
  lease(productId: string): ProClientLease | null;
  current(lease: ProClientLease): boolean;
  intent(lease: ProClientLease, isCurrent: () => boolean): Promise<ProPurchaseIntent>;
  retain(lease: ProClientLease, records: string[]): Promise<void>;
  pending(lease: ProClientLease): Promise<string[]>;
  reconcile(lease: ProClientLease, records: string[]): Promise<ProReconciliationOutcome>;
}
export interface ProBillingProvider {
  product(context: common.UIAbilityContext, id: string): Promise<ProStoreProduct>;
  purchase(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<ProBillingOutcome>;
  restore(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<ProBillingOutcome>;
}
interface ProPurchaseEnvelope { jwsPurchaseOrder: string; }
interface ProPurchaseProductHint { productId: string; }
interface ProRefundOrderHint {
  applicationId: string;
  productId: string;
  productType: string;
  environment: string;
  purchaseOrderId: string;
}

// Native IAP supplies this routing hint solely to open Huawei's refund UI.
// Neither this hint nor the UI result grants or revokes any entitlement.
function sandboxRefundOrder(record: string, lease: ProClientLease): string {
  const envelope = JSON.parse(record) as ProPurchaseEnvelope;
  if (!envelope || typeof envelope.jwsPurchaseOrder !== 'string') { throw new Error('Invalid refund record'); }
  const parts = envelope.jwsPurchaseOrder.split('.');
  if (parts.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(parts[1])) { throw new Error('Invalid refund record'); }
  let encoded = parts[1].replace(/-/g, '+').replace(/_/g, '/');
  while (encoded.length % 4 !== 0) { encoded += '='; }
  const decoded = new util.Base64Helper().decodeSync(encoded);
  const hint = JSON.parse(util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(decoded)) as ProRefundOrderHint;
  if (!hint || hint.productId !== lease.scope.productId) { return ''; }
  if (hint.applicationId !== lease.scope.applicationId || hint.environment !== 'SANDBOX' || hint.productType !== '1' ||
    typeof hint.purchaseOrderId !== 'string' || !/^[^\s\u0000-\u001f\u007f]{1,256}$/.test(hint.purchaseOrderId)) {
    throw new Error('Invalid refund record');
  }
  return hint.purchaseOrderId;
}

export function proRefundError(error: BusinessError): string {
  if (error.code === 1001860000) { return '已取消退款申请，权益仍以服务端核验结果为准。'; }
  if (error.code === 1001860061) { return '该订单已退款或正在退款，请使用恢复购买同步最新权益。'; }
  if (error.code === 1001860062) { return '华为暂不允许此订单退款，请在华为支付页面查看订单状态。'; }
  if (error.message === 'Refund order not unique') { return '未找到唯一的当前沙盒 Pro 订单，无法自动选择退款订单。'; }
  return proBillingError(error);
}
// This hint only routes records. It never grants, acknowledges delivery or
// substitutes for the server's signature and current-order verification.
function recordsForProduct(records: string[], productId: string): string[] {
  proPurchaseBatches(records);
  return records.filter((record: string): boolean => {
    try {
      const envelope = JSON.parse(record) as ProPurchaseEnvelope;
      if (!envelope || typeof envelope.jwsPurchaseOrder !== 'string') { return true; }
      const parts = envelope.jwsPurchaseOrder.split('.');
      if (parts.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(parts[1])) { return true; }
      let encoded = parts[1].replace(/-/g, '+').replace(/_/g, '/');
      while (encoded.length % 4 !== 0) { encoded += '='; }
      const decoded = new util.Base64Helper().decodeSync(encoded);
      const hint = JSON.parse(util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(decoded)) as ProPurchaseProductHint;
      return !hint || typeof hint.productId !== 'string' || hint.productId.length === 0 || hint.productId === productId;
    } catch (_error) { return true; }
  });
}

export function proBillingError(error: BusinessError): string {
  if (error.message === 'Pro service unavailable') { return '沙盒验证服务尚未就绪，请确认服务部署和华为账号登录。'; }
  if (error.message === 'Sandbox required') { return '当前未启用支付沙盒，请检查测试账号和 debug 签名。'; }
  if (error.code === 1001860002) { return '当前测试包未获支付授权（1001860002），请检查 AGC 签名指纹与 IAP 服务配置。'; }
  if (error.code === 1001860050) { return '请先在设备上登录用于沙盒测试的华为账号。'; }
  if (error.code === 1001860003 || error.message === 'Product unavailable') { return '测试商品暂不可用，请检查商品 ID、类型与上架状态。'; }
  if (error.code === 1001860000) { return '已取消购买，你可以稍后再试。'; }
  if (error.code === 1001860057) { return '请安装配置正确的 debug 测试包。'; }
  if (error.code === 1001860058) { return '请在设备上登录已加入 AGC 沙盒名单的华为账号。'; }
  if (error.code === 1001860051) { return '已拥有该商品，请使用恢复购买检查订单。'; }
  if (error.code === 1001860005) { return '网络连接失败，请稍后重试。'; }
  if (error.code === 801) { return '当前设备暂不支持这项支付能力。'; }
  return '未能完成权益验证，请检查网络和沙盒配置，并使用恢复购买重试。';
}

export class HuaweiProBillingProvider implements ProBillingProvider {
  private backend: ProBillingBackend;
  constructor(backend: ProBillingBackend) { this.backend = backend; }
  private capture(id: string): ProClientLease {
    const lease = this.backend.lease(id);
    if (lease === null || lease.scope.environment !== 'sandbox') { throw new Error('Pro service unavailable'); }
    return lease;
  }
  private async sandbox(context: common.UIAbilityContext): Promise<void> {
    if (!await iap.isSandboxActivated(context)) { throw new Error('Sandbox required'); }
  }
  async product(context: common.UIAbilityContext, id: string): Promise<ProStoreProduct> {
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(id)) { throw new Error('Invalid product ID'); }
    const lease = this.capture(id);
    await this.sandbox(context);
    const products = await iap.queryProducts(context, { productType: iap.ProductType.NONCONSUMABLE, productIds: [id] });
    if (!this.backend.current(lease)) { throw new Error('Pro account changed'); }
    const product = products.find((item: iap.Product): boolean => item.id === id && item.type === iap.ProductType.NONCONSUMABLE);
    if (!product || !product.localPrice) { throw new Error('Product unavailable'); }
    return { id: product.id, name: product.name, price: product.localPrice };
  }
  async purchase(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<ProBillingOutcome> {
    const lease = this.capture(id);
    await this.sandbox(context);
    const current = (): boolean => this.backend.current(lease) && isCurrent();
    if (!current()) { return { verified: false, records: 0 }; }
    const intent = await this.backend.intent(lease, current);
    if (!current()) { return { verified: false, records: 0 }; }
    const result = await iap.createPurchase(context, { productType: iap.ProductType.NONCONSUMABLE, productId: id,
      developerPayload: intent.developerPayload });
    // The captured owner survives dismissal/account switch only for retention.
    // Server outbox delivery is the sole finishPurchase authority.
    await this.backend.retain(lease, [result.purchaseData]);
    return { verified: await this.reconcilePending(lease), records: 1 };
  }
  private async reconcilePending(lease: ProClientLease): Promise<boolean> {
    if (!this.backend.current(lease)) { return false; }
    const batches = proPurchaseBatches(await this.backend.pending(lease));
    if (batches.length === 0) { batches.push([]); }
    let active = false;
    for (const batch of batches) {
      if (!this.backend.current(lease)) { return false; }
      const outcome = await this.backend.reconcile(lease, batch);
      if (!outcome.current || !outcome.online) { return false; }
      active = outcome.active;
    }
    return active;
  }
  async restore(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<ProBillingOutcome> {
    const lease = this.capture(id);
    await this.sandbox(context);
    const records: Set<string> = new Set();
    const types: iap.PurchaseQueryType[] = [iap.PurchaseQueryType.CURRENT_ENTITLEMENT, iap.PurchaseQueryType.UNFINISHED];
    for (const queryType of types) {
      let cursor: string | undefined = undefined;
      const seen: string[] = [];
      do {
        if (!this.backend.current(lease) || !isCurrent()) { return { verified: false, records: records.size }; }
        const result: iap.QueryPurchaseResult = await iap.queryPurchases(context, {
          productType: iap.ProductType.NONCONSUMABLE, queryType: queryType, continuationToken: cursor
        });
        const selected = recordsForProduct(result.purchaseDataList, id);
        selected.forEach((value: string): void => { records.add(value); });
        if (records.size > 100) { throw new Error('Too many Pro purchase records'); }
        await this.backend.retain(lease, selected);
        cursor = result.continuationToken;
        if (cursor) {
          if (seen.indexOf(cursor) >= 0 || seen.length >= 100) { throw new Error('Invalid pagination'); }
          seen.push(cursor);
        }
      } while (cursor);
    }
    return { verified: await this.reconcilePending(lease), records: records.size };
  }
  async refund(context: common.UIAbilityContext, id: string, isCurrent: () => boolean): Promise<ProBillingOutcome> {
    if (!DEBUG) { throw new Error('Pro service unavailable'); }
    const lease = this.capture(id);
    const current = (): boolean => this.backend.current(lease) && isCurrent();
    await this.sandbox(context);
    if (!current()) { return { verified: false, records: 0 }; }
    const orders: Set<string> = new Set();
    const seen: string[] = [];
    let count: number = 0;
    let cursor: string | undefined = undefined;
    do {
      if (!current()) { return { verified: false, records: 0 }; }
      const result: iap.QueryPurchaseResult = await iap.queryPurchases(context, { productType: iap.ProductType.NONCONSUMABLE,
        queryType: iap.PurchaseQueryType.CURRENT_ENTITLEMENT, continuationToken: cursor });
      if (!current()) { return { verified: false, records: 0 }; }
      proPurchaseBatches(result.purchaseDataList);
      count += result.purchaseDataList.length;
      if (count > 100) { throw new Error('Too many Pro purchase records'); }
      result.purchaseDataList.forEach((record: string): void => {
        const order = sandboxRefundOrder(record, lease);
        if (order.length > 0) { orders.add(order); }
      });
      cursor = result.continuationToken;
      if (cursor) {
        if (seen.indexOf(cursor) >= 0 || seen.length >= 100) { throw new Error('Invalid pagination'); }
        seen.push(cursor);
      }
    } while (cursor);
    if (orders.size !== 1) { throw new Error('Refund order not unique'); }
    if (!current()) { return { verified: false, records: 0 }; }
    await iap.createRefundRequest(context, Array.from(orders)[0]);
    if (!current()) { return { verified: false, records: 1 }; }
    return { verified: await this.reconcilePending(lease), records: 1 };
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

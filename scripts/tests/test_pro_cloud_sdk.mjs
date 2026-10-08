import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';
import { ProCloudOrderLedger, ProLedgerRecord } from '../../server/pro-entitlement/cloud-ledger.mjs';
import { ownerForUnionId } from '../../server/pro-entitlement/huawei-api.mjs';

const require = createRequire(new URL('../../server/pro-entitlement/agc/package.json', import.meta.url));
// Use the shipped SDK query/transaction/model implementation, replacing only
// the remote transport. Importing the root also starts unrelated auth timers.
const { CloudDBCollection } = require('@hw-agconnect/cloud-server/database-service/CloudDBCollection.js');
const { Transaction } = require('@hw-agconnect/cloud-server/database-service/services/Transaction.js');
const { Utils } = require('@hw-agconnect/cloud-server/database-service/utils/Utils.js');

test('actual Huawei SDK serializes model, version preconditions and complete order transaction', async () => {
  const rows = new Map(); const transactions = []; let version = 0;
  const zone = {
    async executeTransactionQuery(query) {
      let result = [...rows.values()].map(row => ({ ...row }));
      let limit = 1000;
      for (const condition of query.getQueryConditions()) {
        const { conditionType, fieldName, value } = condition;
        if (conditionType === 'EqualTo') result = result.filter(row => row[fieldName] === value);
        else if (conditionType === 'GreaterThan') result = result.filter(row => row[fieldName] > value);
        else if (conditionType === 'LessThanOrEqualTo') result = result.filter(row => row[fieldName] <= value);
        else if (conditionType === 'Limit') limit = value.number;
        else if (conditionType === 'OrderBy') result.sort((a, b) => a[fieldName] - b[fieldName]);
        else assert.fail('Unexpected SDK condition ' + conditionType);
      }
      return result.slice(0, limit);
    },
    async runTransaction(action) {
      const transaction = new Transaction(zone);
      assert.equal(await action.apply(transaction), true);
      transaction.sortVerifyObjectsList();
      const verified = transaction.needVerifyObjectsList.flatMap(group => group.objects);
      assert.ok(verified.some(row => row.id === 'control-v1' && row.naturalbase_version));
      const writes = transaction.transactionList.flatMap(operation => {
        assert.equal(operation.objectTypeName, 'ProLedgerRecord'); assert.equal(operation.operationType, 'Upsert');
        return operation.objects;
      });
      assert.ok(writes.some(row => row.id === 'control-v1'));
      for (const row of writes) {
        assert.equal(row.naturalbase_version, undefined);
        rows.set(row.id, { ...row, naturalbase_version: String(++version) });
      }
      transactions.push({ verified, writes }); transaction.release(); return true;
    }
  };
  const configuration = { applicationId: 'test-app', productId: 'test-pro', environment: 'SANDBOX' };
  const ledger = new ProCloudOrderLedger(new CloudDBCollection(zone, ProLedgerRecord), configuration, randomBytes(32));
  const initial = Utils.serializeObjects([ledger.initialControlRecord()])[0];
  rows.set(initial.id, { ...initial, naturalbase_version: String(++version) });
  const owner = ownerForUnionId('actual-sdk-contract'); const now = Date.now();
  const intent = await ledger.createIntent(owner, now);
  const order = { ...configuration, purchaseOrderId: 'sdk-order', purchaseToken: 'private-sdk-token',
    developerPayload: intent.developerPayload, purchaseTime: now, signedTime: now, needsFinish: true, revoked: false };
  await ledger.applyCurrentOrder(order, owner, now);
  assert.equal(transactions.at(-1).writes.length, 5);
  assert.deepEqual(await ledger.references(owner, true), [{ purchaseOrderId: order.purchaseOrderId, purchaseToken: order.purchaseToken }]);
  assert.equal((await ledger.dueOrders(now)).length, 1);
  const lease = await ledger.claimFinish(order, now); assert.ok(lease);
  await ledger.finishSucceeded(order.purchaseOrderId, lease);
  assert.deepEqual(await ledger.snapshot(owner), { status: 'verified', revision: 1, pending: false, checkedAt: 0 });
  assert.equal(JSON.stringify([...rows.values()]).includes(order.purchaseToken), false);
  ledger.close();
});

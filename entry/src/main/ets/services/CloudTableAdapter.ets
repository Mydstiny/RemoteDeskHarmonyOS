/**
 * CloudTableAdapter — 既有云表与本地行之间的字段白名单适配。
 *
 * 云表结构是外部契约，不能把本地新增字段直接写入云端。该模块保持纯函数，
 * 方便在 CRUD、备份和测试中复用；敏感值仍由 CloudStore/DataCrypto 负责加密。
 */

import {
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_RECORD_COLUMNS
} from '../model/MoonlightRecord';

const CLOUD_COLUMNS: Record<string, string[]> = {
  'cryptoparams': ['id', 'key', 'value'],
  'rdpcredentials': [
    'id', 'userid', 'label', 'username', 'password', 'createdat', 'updatedat'
  ],
  'remotehosts': [
    'id', 'userid', 'label', 'protocol', 'host', 'port', 'username', 'passward',
    'customhostname', 'sshusekey', 'sshkeypath', 'sshkeydata', 'proxyhost', 'proxyport',
    'proxyusername', 'gatewayhost', 'gatewayport', 'displayconfig', 'locked', 'locktype',
    'isfavorite', 'groupid', 'sortorder', 'icon', 'lastconnected', 'lasthealth', 'lastlatency',
    'syncversion', 'createdat', 'updatedat'
  ],
  'rustdeskrelays': [
    'id', 'userid', 'idserver', 'idserverport', 'relayserver', 'relayport', 'apiserver',
    'apiusername', 'apipassword', 'key', 'healthstatus', 'healthlatency', 'healthcheckedat',
    'apiloginstatus', 'accountsjson', 'syncversion', 'createdat', 'updatedat'
  ],
  'sshkeys': [
    'id', 'userid', 'label', 'keytype', 'publickey', 'privatekey', 'fingerprint', 'comment',
    'locked', 'locktype', 'syncversion', 'createdat', 'updatedat'
  ],
  'totpentries': [
    'id', 'userid', 'issuer', 'account', 'displayname', 'secret', 'algorithm', 'digits', 'period', 'iconurl',
    'locked', 'locktype', 'syncversion', 'createdat', 'updatedat'
  ],
  'usersettings': ['id', 'userid', 'payload', 'schemaversion', 'updatedat'],
  // VNC owns one cloud table. Logical record types are separated by
  // `recordtype`; no VNC column is added to an existing protocol table.
  'vncrecordv2': [
    'id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
    'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
    'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'
  ],
  // D2 only defines the exact adapter contract. This does not register the
  // table in CloudSyncPolicy; distributed registration waits for all AGC
  // environment receipts.
  'moonlightrecordv1': [
    'id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
    'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
    'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'
  ]
};

const LOCAL_ONLY_COLUMNS: Record<string, string[]> = {
  'remotehosts': [
    'password', 'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm',
    'sshproxypassword', 'sshproxykeypassphrase',
    'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat',
    'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject',
    'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatenotbeforems',
    'rdpcertificatenotafterms', 'rdpcertificatetrustedat',
    'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot',
    'rdpcertificateallowhostmismatch', 'rdpcertificaterouteidentity',
    'rdpgatewaycertificatefingerprintsha256', 'rdpgatewaycertificatesubject',
    'rdpgatewaycertificateissuer', 'rdpgatewaycertificatecommonname',
    'rdpgatewaycertificatenotbeforems', 'rdpgatewaycertificatenotafterms',
    'rdpgatewaycertificatetrustedat', 'rdpgatewaycertificatetrustmode',
    'rdpgatewaycertificateallowuntrustedroot',
    'rdpgatewaycertificateallowhostmismatch', 'rdpgatewaycertificaterouteidentity',
    'rustdeskrelayid', 'rustdeskaccountid',
    'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled',
    'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'sourcetype',
    'rustdesktargetdevice', 'rustdeskadaptiveorientation'
  ],
  'sshkeys': ['formatversion', 'privatekeyencrypted'],
  'usersettings': ['key', 'value'],
  'moonlightrecordv1': ['localonly']
};

// 这些字段在既有 remotehosts 云表中没有独立列，但属于跨设备连接配置。
// 密码、SSH/RDP 设备信任和本机授权决策绝不进入该扩展。Peer TOTP
// binding 是设备 owner-scoped 本地数据，严禁借 displayconfig 扩展跨设备。
const REMOTE_HOST_CLOUD_EXTENSION_COLUMNS: string[] = [
  'sshkeyid', 'rustdeskrelayid', 'rustdeskaccountid',
  'rustdeskpasswordmode', 'rustdeskauthmode',
  'rustdeskdirectenabled', 'rustdeskdirecthost', 'rustdeskdirectport', 'sshproxytype',
  'sshproxyauthmethod', 'sshproxykeyid',
  'rdpcredentialid', 'rdpauthmode', 'rdprestrictedadminsecretsource', 'sourcetype',
  'rdpendpointmode', 'rdpgatewaytransport', 'rdpgatewayservername', 'rdpclienthostname',
  'rustdesktargetdevice', 'rustdeskadaptiveorientation',
  'lanaddressmode', 'landiscoveryidentity', 'lanlastresolvedat'
];

const REMOTE_HOST_EXTENSION_KEY: string = '_remoteDeskExtensionV1';

export class RemoteHostDisplayPayload {
  displayConfigJson: string = '{}';
  extension: Record<string, string> = {};
}

export function cloudTableColumns(table: string): string[] {
  return CLOUD_COLUMNS[table] ? CLOUD_COLUMNS[table].slice() : [];
}

export function localOnlyColumns(table: string): string[] {
  return LOCAL_ONLY_COLUMNS[table] ? LOCAL_ONLY_COLUMNS[table].slice() : [];
}

/** 将本地完整行投影为云端允许的字段集合。 */
export function projectLocalRow(table: string, local: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  const columns: string[] = cloudTableColumns(table);
  for (let i = 0; i < columns.length; i++) {
    const cloudColumn: string = columns[i];
    if (cloudColumn === 'passward') {
      // `passward` is the existing cloud contract. Once a row has been
      // migrated it must win over the retired local `password` shadow.
      if (local['passward'] !== undefined) { result['passward'] = local['passward']; }
      else if (local['password'] !== undefined) { result['passward'] = local['password']; }
    } else if (local[cloudColumn] !== undefined) {
      result[cloudColumn] = local[cloudColumn];
    }
  }
  return result;
}

/** 将云端 remotehosts 行转换为本地字段名，兼容云端的 passward 拼写。 */
export function normalizeCloudRow(table: string, cloud: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  const columns: string[] = cloudTableColumns(table);
  for (let i = 0; i < columns.length; i++) {
    const column: string = columns[i];
    if (cloud[column] !== undefined) { result[column] = cloud[column]; }
  }
  if (table === 'remotehosts' && cloud['passward'] !== undefined) {
    result['password'] = cloud['passward'];
  }
  return result;
}

function rowHasExactColumns(row: Record<string, string>, columns: string[]): boolean {
  const keys: string[] = Object.keys(row);
  if (keys.length !== columns.length) { return false; }
  for (let i = 0; i < columns.length; i++) {
    if (row[columns[i]] === undefined) { return false; }
  }
  return true;
}

/** Moonlight cloud downloads fail closed on every missing or unknown column. */
export function moonlightCloudRowHasExactColumns(
  row: Record<string, string>
): boolean {
  return rowHasExactColumns(row, MOONLIGHT_RECORD_COLUMNS);
}

/**
 * Project an eligible 20-column local mirror row to the exact 19-column cloud
 * envelope. `localonly=1` is a hard denial, never a value to normalize away.
 */
export function projectMoonlightLocalRowForCloud(
  local: Record<string, string>
): Record<string, string> | null {
  if (!rowHasExactColumns(local, MOONLIGHT_LOCAL_RECORD_COLUMNS) ||
      local['localonly'] !== '0') { return null; }
  const projected: Record<string, string> = {};
  for (let i = 0; i < MOONLIGHT_RECORD_COLUMNS.length; i++) {
    const key: string = MOONLIGHT_RECORD_COLUMNS[i];
    projected[key] = local[key];
  }
  return rowHasExactColumns(projected, cloudTableColumns(MOONLIGHT_CLOUD_TABLE)) ?
    projected : null;
}

/** Copy only after exact shape admission; no default values are manufactured. */
export function normalizeMoonlightCloudRowExact(
  cloud: Record<string, string>
): Record<string, string> | null {
  if (!moonlightCloudRowHasExactColumns(cloud) ||
      !rowHasExactColumns(cloud, cloudTableColumns(MOONLIGHT_CLOUD_TABLE))) {
    return null;
  }
  const result: Record<string, string> = {};
  for (let i = 0; i < MOONLIGHT_RECORD_COLUMNS.length; i++) {
    result[MOONLIGHT_RECORD_COLUMNS[i]] = cloud[MOONLIGHT_RECORD_COLUMNS[i]];
  }
  return result;
}

/** 将云表没有独立列的非敏感主机配置投影为可移植扩展。 */
export function projectRemoteHostCloudExtension(values: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  for (let i = 0; i < REMOTE_HOST_CLOUD_EXTENSION_COLUMNS.length; i++) {
    const key: string = REMOTE_HOST_CLOUD_EXTENSION_COLUMNS[i];
    if (values[key] !== undefined) { result[key] = values[key]; }
  }
  return result;
}

/**
 * 复用既有 displayconfig 云列保存扩展，不改变云表结构。
 * 原显示字段仍保留在 JSON 顶层，旧版本会忽略未知扩展键并继续读取分辨率。
 */
export function encodeRemoteHostDisplayPayload(
  displayConfigJson: string,
  extension: Record<string, string>
): string {
  try {
    const payload: Record<string, Object> =
      JSON.parse(displayConfigJson || '{}') as Record<string, Object>;
    payload[REMOTE_HOST_EXTENSION_KEY] = extension;
    return JSON.stringify(payload);
  } catch (_e) {
    return displayConfigJson;
  }
}

/** 兼容没有扩展键的历史 displayconfig JSON。 */
export function decodeRemoteHostDisplayPayload(raw: string): RemoteHostDisplayPayload {
  const result = new RemoteHostDisplayPayload();
  result.displayConfigJson = raw || '{}';
  try {
    const payload: Record<string, Object> = JSON.parse(raw || '{}') as Record<string, Object>;
    const extension: Record<string, string> =
      payload[REMOTE_HOST_EXTENSION_KEY] as Record<string, string>;
    if (extension) { result.extension = projectRemoteHostCloudExtension(extension); }
  } catch (_e) {
    // 保留原字符串，显示配置调用方沿用既有容错逻辑。
  }
  return result;
}

export function encodeUserSettingsPayload(rows: Array<Record<string, string>>): string {
  const payload: Record<string, Object> = {};
  for (let i = 0; i < rows.length; i++) {
    const key: string = rows[i]['key'] || '';
    if (key === '') { continue; }
    try {
      payload[key] = JSON.parse(rows[i]['value'] || 'null') as Object;
    } catch (_e) {
      // 坏设置不进入云端 payload，保留在本地并由调用方记录诊断。
    }
  }
  return JSON.stringify(payload);
}

export function decodeUserSettingsPayload(
  row: Record<string, string>
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  try {
    const payload: Record<string, Object> = JSON.parse(row['payload'] || '{}') as Record<string, Object>;
    const keys: string[] = Object.keys(payload);
    for (let i = 0; i < keys.length; i++) {
      const item: Record<string, string> = {};
      item['id'] = 'setting:' + keys[i];
      item['userid'] = row['userid'] || '';
      item['key'] = keys[i];
      item['value'] = JSON.stringify(payload[keys[i]]);
      item['updatedat'] = row['updatedat'] || '0';
      result.push(item);
    }
  } catch (_e) {
    return [];
  }
  return result;
}

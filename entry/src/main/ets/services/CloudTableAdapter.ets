/**
 * CloudTableAdapter — 既有云表与本地行之间的字段白名单适配。
 *
 * 云表结构是外部契约，不能把本地新增字段直接写入云端。该模块保持纯函数，
 * 方便在 CRUD、备份和测试中复用；敏感值仍由 CloudStore/DataCrypto 负责加密。
 */

const CLOUD_COLUMNS: Record<string, string[]> = {
  'cryptoparams': ['id', 'key', 'value'],
  'rdpcredentials': ['id', 'label', 'password', 'createdat', 'updatedat'],
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
    'id', 'userid', 'issuer', 'account', 'secret', 'algorithm', 'digits', 'period', 'iconurl',
    'locked', 'locktype', 'syncversion', 'createdat', 'updatedat'
  ],
  'usersettings': ['id', 'userid', 'payload', 'schemaversion', 'updatedat']
};

const LOCAL_ONLY_COLUMNS: Record<string, string[]> = {
  'remotehosts': [
    'password', 'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm',
    'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat',
    'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject',
    'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatetrustedat',
    'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot',
    'rdpcertificateallowhostmismatch', 'rustdeskrelayid', 'rustdeskaccountid',
    'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled',
    'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'sourcetype',
    'rustdeskproaccountid', 'rustdeskpropeerid', 'rustdeskproplatform',
    'rustdeskpromanaged', 'rustdeskprolastseenat', 'rustdeskprosyncerror'
  ],
  'rdpcredentials': ['username'],
  'sshkeys': ['formatversion', 'privatekeyencrypted'],
  'usersettings': ['key', 'value']
};

// 这些字段在既有 remotehosts 云表中没有独立列，但属于跨设备连接配置。
// password 已由 passward 同步；sshkeypassphrase 不进入复用字段，避免敏感值泄漏。
const REMOTE_HOST_CLOUD_EXTENSION_COLUMNS: string[] = [
  'sshkeyid', 'sshhostkeyalgorithm', 'sshhostkeyfingerprintsha256',
  'sshhostkeyrawbase64', 'sshhostkeytrustedat', 'sshhostkeytrustmode',
  'rdpcertificatefingerprintsha256', 'rdpcertificatesubject', 'rdpcertificateissuer',
  'rdpcertificatecommonname', 'rdpcertificatetrustedat', 'rdpcertificatetrustmode',
  'rdpcertificateallowuntrustedroot', 'rdpcertificateallowhostmismatch',
  'rustdeskrelayid', 'rustdeskaccountid', 'rustdeskpasswordmode', 'rustdeskauthmode',
  'rustdeskdirectenabled', 'rustdeskdirecthost', 'rustdeskdirectport',
  'rdpcredentialid', 'sourcetype', 'rustdeskproaccountid', 'rustdeskpropeerid',
  'rustdeskproplatform', 'rustdeskpromanaged', 'rustdeskprolastseenat',
  'rustdeskprosyncerror'
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
      if (local['password'] !== undefined) { result['passward'] = local['password']; }
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

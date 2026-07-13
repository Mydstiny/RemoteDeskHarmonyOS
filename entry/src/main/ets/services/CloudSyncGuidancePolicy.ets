export interface CloudSyncDetailSpec {
  statusText: string;
  statusAvailable: boolean;
  prerequisites: string[];
}

const PREREQUISITES: string[] = [
  '登录与其他设备相同的华为账号',
  '已开通华为云空间服务',
  '系统设置中的云同步开关已打开',
  '设备网络可用'
];

export function cloudSyncDetailSpec(cloudReady: boolean): CloudSyncDetailSpec {
  return {
    statusAvailable: cloudReady,
    statusText: cloudReady ? '应用端云数据库已就绪' : '应用暂未建立端云连接，请检查使用条件',
    prerequisites: PREREQUISITES.slice()
  };
}

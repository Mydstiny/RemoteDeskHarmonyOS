#pragma once

#include <string>
#include <vector>

// 远程主机数据模型（与 Cloud DB 数据模型一致）
struct RemoteHost {
    std::string id;             // 主机唯一标识
    std::string userId;         // 所属用户（华为账号 UnionID）
    std::string label;          // 主机显示名
    std::string protocol;       // 协议类型："rdp" | "rustdesk"
    std::string host;           // IP 或域名
    int port = 3389;            // 端口
    std::string username;       // 登录用户名
    bool locked = false;        // 是否已加锁
    std::string lockType;       // 锁类型："none" | "biometric" | "pin" | "password"
    int syncVersion = 0;        // 云同步版本号（冲突检测用）
};

// DataProvider 接口 — 所有数据存储方式必须实现的纯虚接口
class DataProvider {
public:
    virtual ~DataProvider() = default;

    virtual std::string provider_name() = 0;                       // 存储方式名称："clouddb", "local_encrypt"

    virtual std::vector<RemoteHost> load_hosts(const std::string& userId) = 0;  // 加载用户的主机列表
    virtual bool save_host(const RemoteHost& host) = 0;                          // 保存/更新主机
    virtual bool delete_host(const std::string& hostId) = 0;                     // 删除指定主机
    virtual int sync_from_cloud(const std::string& userId) = 0;                  // 从云端同步，返回最新版本号
};

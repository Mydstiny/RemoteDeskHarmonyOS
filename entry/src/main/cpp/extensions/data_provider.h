/**
 * data_provider.h — 数据存储提供者接口
 *
 * 抽象远程主机配置的持久化和云端同步。
 * 支持多种存储后端：CloudDB 云同步、本地加密存储、自定义后端。
 * 通过 ExtensionSystem::instance().storage 注册。
 */

#ifndef DATA_PROVIDER_H
#define DATA_PROVIDER_H

#include <functional>
#include <string>
#include <vector>

// ============================================================
// 数据结构
// ============================================================

/** 锁类型枚举 */
enum class LockType {
    NONE      = 0,  // 未加锁
    BIOMETRIC = 1,  // 生物识别（指纹/人脸）
    PIN       = 2,  // PIN 码
    PASSWORD  = 3   // 密码
};

/** 远程主机配置 — 与 ArkTS RemoteHost 模型对应 */
struct RemoteHostData {
    std::string id;           // 主机唯一 ID (UUID)
    std::string userId;       // 关联的华为账号 UnionID
    std::string label;        // 主机显示名
    std::string protocol;     // 协议类型 ("rdp" | "rustdesk")
    std::string host;         // IP 或域名
    int         port;         // 端口号
    std::string username;     // 登录用户名
    bool        locked;       // 是否已加安全锁
    LockType    lockType;     // 锁类型
    int         syncVersion;  // 同步版本号 (冲突检测)
    std::string icon;         // 主机图标 (可选)
    int64_t     lastConnected;// 最后连接时间戳 (ms)
    int64_t     createdAt;    // 创建时间戳 (ms)

    RemoteHostData()
        : port(3389), locked(false), lockType(LockType::NONE),
          syncVersion(0), lastConnected(0), createdAt(0) {}
};

/** 同步结果 */
struct SyncResult {
    bool               success;
    int                version;         // 最新同步版本号
    std::string        errorMessage;
    std::vector<RemoteHostData> hosts;  // 合并后的主机列表

    SyncResult() : success(false), version(0) {}
};

// ============================================================
// 回调类型
// ============================================================

/** 同步完成回调 */
using SyncCallback = std::function<void(const SyncResult& result)>;

/** 数据变更回调 (某个主机被修改时触发) */
using DataChangeCallback = std::function<void(const std::string& hostId,
                                                const std::string& operation)>;

// ============================================================
// DataProvider 接口
// ============================================================

/**
 * DataProvider — 数据存储提供者接口
 *
 * 所有存储后端（CloudDB 云同步、本地加密存储...）必须实现此接口。
 * 通过 ExtensionSystem::instance().storage 注册。
 */
class DataProvider {
public:
    virtual ~DataProvider() = default;

    // ---- 元信息 ----

    /** 存储提供者名称 (如 "clouddb", "local_encrypted") */
    virtual std::string providerName() = 0;

    /** 是否支持云端同步 */
    virtual bool supportsCloudSync() { return false; }

    // ---- CRUD 操作 ----

    /**
     * 加载指定用户的所有远程主机配置
     * @param userId  用户唯一标识
     * @return 主机配置列表
     */
    virtual std::vector<RemoteHostData> loadHosts(const std::string& userId) = 0;

    /**
     * 保存指定用户的远程主机配置 (全量覆盖)
     * @param userId  用户唯一标识
     * @param hosts   主机配置列表
     * @return 是否成功
     */
    virtual bool saveHosts(const std::string& userId,
                           const std::vector<RemoteHostData>& hosts) = 0;

    /**
     * 添加单个主机配置
     * @param userId  用户唯一标识
     * @param host    主机配置
     * @return 是否成功
     */
    virtual bool addHost(const std::string& userId,
                         const RemoteHostData& host) = 0;

    /**
     * 更新单个主机配置
     * @param userId  用户唯一标识
     * @param host    新的主机配置 (以 id 匹配)
     * @return 是否成功
     */
    virtual bool updateHost(const std::string& userId,
                            const RemoteHostData& host) = 0;

    /**
     * 删除单个主机配置
     * @param userId  用户唯一标识
     * @param hostId  要删除的主机 ID
     * @return 是否成功
     */
    virtual bool removeHost(const std::string& userId,
                            const std::string& hostId) = 0;

    // ---- 云同步 ----

    /**
     * 从云端同步主机配置
     * @param userId    用户唯一标识
     * @param callback  同步结果回调
     */
    virtual void syncFromCloud(const std::string& userId,
                               SyncCallback callback) = 0;

    /**
     * 推送本地变更到云端
     * @param userId    用户唯一标识
     * @param callback  同步结果回调
     */
    virtual void pushToCloud(const std::string& userId,
                             SyncCallback callback) = 0;

    // ---- 冲突解决 ----

    /**
     * 三路合并冲突解决
     * @param local   本地版本
     * @param remote  远程版本
     * @param base    共同祖先版本
     * @return 合并后的版本 (syncVersion 递增)
     */
    virtual RemoteHostData resolveConflict(const RemoteHostData& local,
                                           const RemoteHostData& remote,
                                           const RemoteHostData& base) {
        // 默认策略：remote wins (以云端为准)
        return remote;
    }

    // ---- 数据变更监听 ----

    /** 注册数据变更监听器 */
    virtual void addDataChangeListener(DataChangeCallback callback) = 0;

    /** 移除数据变更监听器 */
    virtual void removeDataChangeListener(DataChangeCallback callback) = 0;
};

#endif // DATA_PROVIDER_H

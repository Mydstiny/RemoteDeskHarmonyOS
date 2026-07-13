/**
 * extension_registry.h — 可扩展架构核心：扩展注册中心
 *
 * 设计原则：面向扩展开放，面向修改封闭。
 * 所有新功能（协议适配器、认证方式、UI组件、存储后端）
 * 都通过此注册中心以插件形式注册，不修改核心框架代码。
 *
 * 使用方式：
 *   ExtensionSystem::instance().protocols.register("protocol", "rdp",
 *       std::make_shared<FreeRdpAdapter>());
 *   auto adapters = ExtensionSystem::instance().protocols.get("protocol");
 */

#ifndef EXTENSION_REGISTRY_H
#define EXTENSION_REGISTRY_H

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

/**
 * ExtensionRegistry — 泛型扩展注册表
 *
 * @tparam T  扩展接口类型（纯虚基类）
 *
 * 扩展点命名规范： "类别.名称"，例如：
 *   - "protocol.rdp"     → RDP 协议适配器
 *   - "protocol.rustdesk"→ RustDesk 协议适配器
 *   - "auth.huawei"      → 华为账号认证
 *   - "toolbar.lock"     → 主机锁按钮
 */
template<typename T>
class ExtensionRegistry {
public:
    ExtensionRegistry() = default;
    ~ExtensionRegistry() = default;

    /**
     * 注册一个扩展
     * @param point  扩展点类别 (如 "protocol", "auth", "toolbar", "storage")
     * @param name   扩展名称 (如 "rdp", "huawei", "lock")
     * @param ext    扩展实例 (shared_ptr)
     */
    void registerExt(const std::string& point, const std::string& name,
                  std::shared_ptr<T> ext) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::string key = point + "." + name;
        extensions_[key] = ext;
    }

    /**
     * 获取指定扩展点的所有注册扩展
     * @param point  扩展点类别
     * @return 该类别下所有扩展实例的列表
     */
    std::vector<std::shared_ptr<T>> get(const std::string& point) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::shared_ptr<T>> result;
        for (const auto& [key, ext] : extensions_) {
            // 检查 key 是否以 "point." 开头
            if (key.size() > point.size() &&
                key.compare(0, point.size(), point) == 0 &&
                key[point.size()] == '.') {
                result.push_back(ext);
            }
        }
        return result;
    }

    /**
     * 获取指定扩展点下指定名称的扩展
     * @param point  扩展点类别
     * @param name   扩展名称
     * @return 扩展实例指针，未找到返回 nullptr
     */
    std::shared_ptr<T> getByName(const std::string& point,
                                  const std::string& name) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::string key = point + "." + name;
        auto it = extensions_.find(key);
        if (it != extensions_.end()) {
            return it->second;
        }
        return nullptr;
    }

    /**
     * 获取所有已注册扩展的名称列表
     * @param point  扩展点类别
     * @return 扩展名称列表
     */
    std::vector<std::string> listNames(const std::string& point) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::string> result;
        for (const auto& [key, ext] : extensions_) {
            if (key.size() > point.size() &&
                key.compare(0, point.size(), point) == 0 &&
                key[point.size()] == '.') {
                result.push_back(key.substr(point.size() + 1));
            }
        }
        return result;
    }

    /**
     * 注销一个扩展
     * @param point  扩展点类别
     * @param name   扩展名称
     * @return 是否成功移除
     */
    bool unregister(const std::string& point, const std::string& name) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::string key = point + "." + name;
        return extensions_.erase(key) > 0;
    }

    /**
     * 获取已注册扩展总数
     */
    size_t size() const {
        return extensions_.size();
    }

private:
    std::map<std::string, std::shared_ptr<T>> extensions_;
    std::mutex mutex_;
};

// 前向声明 — 实际类型在各自头文件中定义
class ProtocolAdapter;
class AuthProvider;
class ToolbarExtension;
class DataProvider;

/**
 * ExtensionSystem — 全局扩展系统单例
 *
 * 包含四个核心扩展注册表：
 *   - protocols: 远程协议适配器 (RDP, RustDesk, VNC...)
 *   - auth:      认证提供者 (华为账号, 本地密码, SSO...)
 *   - toolbar:   工具栏扩展 (主机锁按钮, 截图, 文件传输...)
 *   - storage:   数据存储提供者 (CloudDB, 本地加密, ...)
 */
class ExtensionSystem {
public:
    ExtensionRegistry<ProtocolAdapter>   protocols;
    ExtensionRegistry<AuthProvider>      auth;
    ExtensionRegistry<ToolbarExtension>  toolbar;
    ExtensionRegistry<DataProvider>      storage;

    /**
     * 获取全局单例
     */
    static ExtensionSystem& instance() {
        static ExtensionSystem sys;
        return sys;
    }

private:
    ExtensionSystem() = default;
    ExtensionSystem(const ExtensionSystem&) = delete;
    ExtensionSystem& operator=(const ExtensionSystem&) = delete;
};

#endif // EXTENSION_REGISTRY_H

#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "protocol_adapter.h"
#include "auth_provider.h"
#include "data_provider.h"

// 工具栏扩展（外部插件实现，此处仅做前向声明）
class ToolbarExtension;

// ExtensionRegistry — 模板化扩展注册中心
// 按 Extension Point + 名称注册/查找扩展实例
template<typename T>
class ExtensionRegistry {
    std::map<std::string, std::shared_ptr<T>> extensions_;

public:
    // 注册扩展：point 为扩展点名称，name 为扩展实例名称
    void register_extension(const std::string& point, const std::string& name,
                            std::shared_ptr<T> ext) {
        extensions_[point + "." + name] = ext;
    }

    // 获取指定扩展点下的所有已注册扩展
    std::vector<std::shared_ptr<T>> get(const std::string& point) {
        std::vector<std::shared_ptr<T>> result;
        for (auto& [key, ext] : extensions_) {
            if (key.starts_with(point)) {
                result.push_back(ext);
            }
        }
        return result;
    }

    // 根据完整键名精确获取扩展
    std::shared_ptr<T> get_by_key(const std::string& key) {
        auto it = extensions_.find(key);
        return it != extensions_.end() ? it->second : nullptr;
    }

    // 获取所有已注册扩展的总数
    size_t size() const {
        return extensions_.size();
    }
};

// ExtensionSystem — 全局扩展系统单例
// 持有所有 Extension Point 的注册中心
class ExtensionSystem {
public:
    ExtensionRegistry<ProtocolAdapter>   protocols;   // 协议适配器扩展点
    ExtensionRegistry<AuthProvider>      auth;         // 认证方式扩展点
    ExtensionRegistry<ToolbarExtension>  toolbar;      // 工具栏按钮扩展点
    ExtensionRegistry<DataProvider>      storage;      // 数据存储扩展点

    static ExtensionSystem& instance() {
        static ExtensionSystem sys;
        return sys;
    }

private:
    ExtensionSystem() = default;
    ~ExtensionSystem() = default;
    ExtensionSystem(const ExtensionSystem&) = delete;
    ExtensionSystem& operator=(const ExtensionSystem&) = delete;
};

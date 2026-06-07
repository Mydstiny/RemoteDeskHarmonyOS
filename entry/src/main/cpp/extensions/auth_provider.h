#pragma once

#include <string>

// 用户信息结构体
struct UserInfo {
    std::string userId;         // 用户唯一标识（华为 UnionID）
    std::string displayName;    // 用户显示名
    std::string avatarUrl;      // 头像 URL
    std::string email;          // 邮箱地址
};

// 认证结果枚举
enum class AuthResult {
    SUCCESS,    // 认证成功
    FAILED,     // 认证失败
    CANCELLED,  // 用户取消
    ERROR       // 系统错误
};

// AuthProvider 接口 — 所有认证方式必须实现的纯虚接口
class AuthProvider {
public:
    virtual ~AuthProvider() = default;

    virtual std::string provider_name() = 0;               // 认证方式名称："huawei", "local", "sso"

    virtual AuthResult authenticate(const std::string& credential) = 0;  // 执行认证
    virtual bool is_authenticated() = 0;                                 // 当前是否已认证
    virtual UserInfo get_user_info() = 0;                                // 获取已认证用户信息
    virtual void sign_out() = 0;                                         // 登出
};

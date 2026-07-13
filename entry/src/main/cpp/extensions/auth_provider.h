/**
 * auth_provider.h — 认证提供者接口
 *
 * 定义用户身份认证的标准接口。
 * 支持多种认证方式：华为账号、本地密码、企业 SSO 等。
 * 通过 ExtensionSystem::instance().auth 注册。
 */

#ifndef AUTH_PROVIDER_H
#define AUTH_PROVIDER_H

#include <functional>
#include <string>

// ============================================================
// 数据结构
// ============================================================

/** 认证结果 */
struct AuthResult {
    bool        success;        // 是否成功
    std::string token;          // 认证令牌 (ID Token / Access Token)
    std::string userId;         // 用户唯一标识 (UnionID / OpenID)
    std::string displayName;    // 用户显示名
    std::string avatarUrl;      // 头像 URL (可选)
    std::string errorMessage;   // 错误信息 (失败时)

    AuthResult() : success(false) {}
};

/** 用户信息 (当前登录用户) */
struct UserInfo {
    std::string userId;
    std::string displayName;
    std::string avatarUrl;
    bool        isLoggedIn;

    UserInfo() : isLoggedIn(false) {}
};

// ============================================================
// 回调类型
// ============================================================

/** 登录结果回调 */
using LoginCallback = std::function<void(const AuthResult& result)>;

/** 登录状态变更回调 */
using LoginStateCallback = std::function<void(bool isLoggedIn)>;

// ============================================================
// AuthProvider 接口
// ============================================================

/**
 * AuthProvider — 认证提供者接口
 *
 * 所有认证方式（华为账号、本地密码、企业 SSO...）必须实现此接口。
 * 通过 ExtensionSystem::instance().auth 注册。
 */
class AuthProvider {
public:
    virtual ~AuthProvider() = default;

    // ---- 元信息 ----

    /** 认证方式名称 (如 "huawei", "local", "sso") */
    virtual std::string authName() = 0;

    /** 认证方式显示名称 (如 "华为账号", "本地密码") */
    virtual std::string authDisplayName() = 0;

    // ---- 登录/登出 ----

    /**
     * 发起登录
     * @param callback  登录结果回调
     */
    virtual void login(LoginCallback callback) = 0;

    /** 登出 */
    virtual void logout() = 0;

    /** 是否已登录 */
    virtual bool isLoggedIn() = 0;

    /** 获取当前登录用户信息 */
    virtual UserInfo getCurrentUser() = 0;

    // ---- 令牌管理 ----

    /** 获取当前 Access Token (用于云同步 API 调用) */
    virtual std::string getAccessToken() = 0;

    /** 刷新 Token */
    virtual void refreshToken() {}

    // ---- 状态监听 ----

    /** 注册登录状态变更监听器 */
    virtual void addLoginStateListener(LoginStateCallback callback) = 0;

    /** 移除登录状态变更监听器 */
    virtual void removeLoginStateListener(LoginStateCallback callback) = 0;

    // ---- 扩展功能 ----

    /** 是否支持生物识别登录 */
    virtual bool supportsBiometric() { return false; }

    /** 是否支持多账户切换 */
    virtual bool supportsMultiAccount() { return false; }
};

#endif // AUTH_PROVIDER_H

/**
 * ssh_adapter.cpp — SSH 终端协议适配器实现 (libssh2 集成版)
 *
 * 基于 libssh2 + OpenSSL 的完整 SSH2 协议实现.
 * 连接流程: TCP → KEX(Banner内嵌) → 认证 → 通道 → PTY → Shell
 * 所有 libssh2 调用使用非阻塞模式 + select() 轮询.
 */
#include "ssh_adapter.h"
#include "extension_registry.h"
#include "common/safe_log.h"
#include "ssh_algorithm_prefs.h"
#include <hilog/log.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstring>
#include <cerrno>
#include <mutex>
#include <chrono>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0010
#define LOG_TAG "SSH_ADAPTER"

// ============================================================
// 静态: libssh2 全局初始化 (进程级, 调用一次)
// ============================================================

namespace {
    std::once_flag g_libssh2_init_flag;

    std::string encodeBase64(const unsigned char* data, size_t len) {
        static const char b64chars[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string out;
        out.reserve(((len + 2) / 3) * 4);
        for (size_t i = 0; i < len; i += 3) {
            unsigned int n = static_cast<unsigned int>(data[i]) << 16;
            if (i + 1 < len) {
                n |= static_cast<unsigned int>(data[i + 1]) << 8;
            }
            if (i + 2 < len) {
                n |= static_cast<unsigned int>(data[i + 2]);
            }
            out += b64chars[(n >> 18) & 0x3F];
            out += b64chars[(n >> 12) & 0x3F];
            out += (i + 1 < len) ? b64chars[(n >> 6) & 0x3F] : '=';
            out += (i + 2 < len) ? b64chars[n & 0x3F] : '=';
        }
        return out;
    }

    void ensureLibssh2Init() {
        std::call_once(g_libssh2_init_flag, []() {
            int rc = libssh2_init(0);
            if (rc == 0) {
                OH_LOG_INFO(LOG_APP, "[SSH] libssh2 全局初始化完成");
            } else {
                OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_init 失败: rc=%{public}d", rc);
            }
        });
    }
}

// ============================================================
// 构造 / 析构
// ============================================================

SshAdapter::SshAdapter()
    : sockFd_(-1)
    , state_(ConnectionState::DISCONNECTED)
    , authenticated_(false)
    , session_(nullptr)
    , channel_(nullptr)
    , sftp_(nullptr)
{
    ensureLibssh2Init();
}

SshAdapter::~SshAdapter() {
    disconnect();
}

// ============================================================
// ProtocolAdapter 元信息
// ============================================================

std::string SshAdapter::protocolName() {
    return "SSH";
}

int SshAdapter::defaultPort() {
    return 22;
}

std::string SshAdapter::protocolVersion() {
    return SSH_ADAPTER_VERSION;
}

// ============================================================
// 内部辅助方法
// ============================================================

void SshAdapter::setState(ConnectionState s) {
    state_ = s;
    if (stateCallback_) {
        stateCallback_(s, "");
    }
}

int SshAdapter::waitSocket(int direction, int timeoutSec) {
    fd_set rfds, wfds;
    FD_ZERO(&rfds);
    FD_ZERO(&wfds);
    if (direction == 0 || direction == 2) { FD_SET(sockFd_, &rfds); }
    if (direction == 1 || direction == 2) { FD_SET(sockFd_, &wfds); }
    struct timeval tv = {timeoutSec, 0};
    int ret = select(sockFd_ + 1, &rfds, &wfds, nullptr, &tv);
    if (ret < 0) { return -1; }
    if (ret == 0) { return -2; } // timeout
    return 0;
}

// ============================================================
// TCP 连接
// ============================================================

int SshAdapter::tcpConnect(const std::string& host, int port) {
    const std::string logHost = SafeLog::MaskHost(host);
    sockFd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (sockFd_ < 0) {
        OH_LOG_ERROR(LOG_APP, "[SSH] socket() 失败: %{public}s (%{public}d)",
                     strerror(errno), errno);
        return ERR_SSH_SOCKET_CREATE;
    }

    // 设置非阻塞
    int flags = fcntl(sockFd_, F_GETFL, 0);
    fcntl(sockFd_, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));

    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) <= 0) {
        OH_LOG_ERROR(LOG_APP, "[SSH] inet_pton 失败: %{public}s", logHost.c_str());
        close(sockFd_);
        sockFd_ = -1;
        return ERR_SSH_DNS_RESOLVE;
    }

    OH_LOG_INFO(LOG_APP, "[SSH] 正在连接 %{public}s:%{public}d ...", logHost.c_str(), port);

    int ret = ::connect(sockFd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr));
    if (ret < 0 && errno != EINPROGRESS) {
        OH_LOG_ERROR(LOG_APP, "[SSH] connect() 失败: %{public}s (%{public}d)",
                     strerror(errno), errno);
        close(sockFd_);
        sockFd_ = -1;
        return ERR_SSH_SOCKET_CONNECT;
    }

    // 等待连接完成 (非阻塞)
    if (ret < 0) {
        int w = waitSocket(1, 10); // 10s timeout
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 连接超时: %{public}s:%{public}d", logHost.c_str(), port);
            close(sockFd_);
            sockFd_ = -1;
            return ERR_SSH_CONNECT_TIMEOUT;
        }
    }

    OH_LOG_INFO(LOG_APP, "[SSH] TCP 连接建立成功, fd=%{public}d", sockFd_);
    return 0;
}

// exchangeBanner() 已移除 — libssh2_session_handshake 内部处理 banner 交换

// ============================================================
// SSH 协议方法 (libssh2 集成)
// ============================================================

int SshAdapter::sshHandshake() {
    session_ = libssh2_session_init();
    if (!session_) {
        OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_session_init 失败");
        return ERR_SSH_SESSION_INIT;
    }

    // 非阻塞模式
    libssh2_session_set_blocking(session_, 0);
    // 开启需要回复的 SSH keepalive, 供 UI 延迟检测复用协议级往返.
    libssh2_keepalive_config(session_, 1, 1);

    applySshAlgorithmPreferences(session_);
    OH_LOG_INFO(LOG_APP, "[SSH] 算法偏好已设置");

    // KEX 握手 (非阻塞 + select 轮询)
    int rc;
    while ((rc = libssh2_session_handshake(session_, sockFd_)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30); // 30s KEX timeout
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] KEX 握手超时");
            libssh2_session_free(session_);
            session_ = nullptr;
            return ERR_SSH_KEX_TIMEOUT;
        }
    }
    if (rc) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session_, &errMsg, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] KEX握手失败: rc=%{public}d msg=%{public}s serverBanner=%{public}s",
                     rc, errMsg ? errMsg : "unknown", serverBanner_.c_str());
        libssh2_session_free(session_);
        session_ = nullptr;
        return ERR_SSH_KEX_FAILED;
    }

    // 主机密钥指纹 (SHA256, 用于日志)
    const char* fingerprint = libssh2_hostkey_hash(session_, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (fingerprint) {
        char hex[65];
        for (int i = 0; i < 32; i++) {
            sprintf(hex + i * 2, "%02X", (unsigned char)fingerprint[i]);
        }
        hex[64] = '\0';
        OH_LOG_INFO(LOG_APP, "[SSH] 主机密钥 SHA256: %{public}s", hex);
    }

    // 二次校验 expected host key (防 probe/connect 间 TOCTOU)。
    // 优先比对 raw host key blob, 与 HostList 信任判断使用同一字段。
    if (!savedCfg_.expectedHostKeyRawBase64.empty()) {
        size_t keyLen = 0;
        int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
        const char* rawKey = libssh2_session_hostkey(session_, &keyLen, &keyType);
        if (!rawKey || keyLen == 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 主机密钥二次校验失败: 无法读取 raw host key");
            libssh2_session_free(session_);
            session_ = nullptr;
            return ERR_SSH_HOSTKEY_MISMATCH;
        }
        std::string currentRaw = encodeBase64(reinterpret_cast<const unsigned char*>(rawKey), keyLen);
        if (currentRaw != savedCfg_.expectedHostKeyRawBase64) {
            std::string currentFp = "";
            if (fingerprint) {
                std::string fpB64 = encodeBase64(reinterpret_cast<const unsigned char*>(fingerprint), 32);
                while (!fpB64.empty() && fpB64.back() == '=') {
                    fpB64.pop_back();
                }
                currentFp = "SHA256:" + fpB64;
            }
            OH_LOG_ERROR(LOG_APP,
                "[SSH] 主机密钥 raw 不匹配! expectedLen=%{public}zu currentLen=%{public}zu keyType=%{public}d algorithm=%{public}s currentFp=%{public}s expectedFp=%{public}s",
                savedCfg_.expectedHostKeyRawBase64.size(), currentRaw.size(), keyType,
                sshHostKeyTypeName(keyType), currentFp.c_str(),
                savedCfg_.expectedHostKeyFingerprintSha256.c_str());
            libssh2_session_free(session_);
            session_ = nullptr;
            return ERR_SSH_HOSTKEY_MISMATCH;
        }
        OH_LOG_INFO(LOG_APP, "[SSH] 主机密钥 raw 二次校验通过");
    } else if (!savedCfg_.expectedHostKeyFingerprintSha256.empty() && fingerprint) {
        std::string currentFpB64 = encodeBase64(reinterpret_cast<const unsigned char*>(fingerprint), 32);
        // 去尾部 '=' (OpenSSH 风格)
        while (!currentFpB64.empty() && currentFpB64.back() == '=') {
            currentFpB64.pop_back();
        }
        std::string currentFp = "SHA256:" + currentFpB64;
        if (currentFp != savedCfg_.expectedHostKeyFingerprintSha256) {
            OH_LOG_ERROR(LOG_APP,
                "[SSH] 主机密钥不匹配! expected=%{public}s current=%{public}s",
                savedCfg_.expectedHostKeyFingerprintSha256.c_str(), currentFp.c_str());
            libssh2_session_free(session_);
            session_ = nullptr;
            return ERR_SSH_HOSTKEY_MISMATCH;
        }
        OH_LOG_INFO(LOG_APP, "[SSH] 主机密钥二次校验通过");
    }

    OH_LOG_INFO(LOG_APP, "[SSH] KEX 握手完成");
    return 0;
}

int SshAdapter::authenticatePassword() {
    if (!session_) { return ERR_SSH_AUTH_FAILED; }

    // 查询服务器支持的认证方法
    char* userList = libssh2_userauth_list(session_,
        savedCfg_.username.c_str(), savedCfg_.username.length());
    OH_LOG_INFO(LOG_APP, "[SSH] 服务器认证方法: %{public}s",
                userList ? userList : "(none)");

    // 密码认证 (非阻塞)
    int rc;
    while ((rc = libssh2_userauth_password(session_,
               savedCfg_.username.c_str(),
               savedCfg_.password.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30); // 30s auth timeout
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 密码认证超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    if (rc) {
        const char* errMsg = "未知错误";
        if (rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED) {
            errMsg = "用户名或密码错误";
        } else if (rc == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED) {
            errMsg = "公钥未验证";
        }
        char* detail = nullptr;
        libssh2_session_last_error(session_, &detail, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] 认证失败: %{public}s (rc=%{public}d detail=%{public}s)",
                     errMsg, rc, detail ? detail : "");
        return ERR_SSH_AUTH_FAILED;
    }

    authenticated_ = true;
    OH_LOG_INFO(LOG_APP, "[SSH] 密码认证成功");
    return 0;
}

int SshAdapter::authenticatePublicKey(const std::string& username,
                                       const std::string& privateKeyPem,
                                       const std::string& passphrase) {
    if (!session_) { return ERR_SSH_AUTH_FAILED; }

    // 诊断: 仅输出密钥长度, 不泄露内容
    OH_LOG_INFO(LOG_APP, "[SSH] 密钥数据 len=%{public}zu", privateKeyPem.size());

    const char* pass = passphrase.empty() ? nullptr : passphrase.c_str();

    int rc;
    while ((rc = libssh2_userauth_publickey_frommemory(
                session_,
                username.c_str(), username.length(),
                nullptr, 0,
                privateKeyPem.c_str(), privateKeyPem.length(),
                pass)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 公钥认证超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    if (rc != 0) {
        char* detail = nullptr;
        libssh2_session_last_error(session_, &detail, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] 公钥认证失败: rc=%{public}d detail=%{public}s",
                     rc, detail ? detail : "");
        return ERR_SSH_AUTH_FAILED;
    }

    authenticated_ = true;
    OH_LOG_INFO(LOG_APP, "[SSH] 公钥认证成功 (OpenSSL 后端)");
    return 0;
}

int SshAdapter::openChannel() {
    if (!session_) { return ERR_SSH_CHANNEL_OPEN; }

    while ((channel_ = libssh2_channel_open_session(session_)) == nullptr) {
        if (libssh2_session_last_errno(session_) == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15); // 15s channel timeout
            if (w != 0) {
                OH_LOG_ERROR(LOG_APP, "[SSH] 打开通道超时");
                return ERR_SSH_CHANNEL_OPEN;
            }
        } else {
            char* errMsg = nullptr;
            libssh2_session_last_error(session_, &errMsg, nullptr, 0);
            OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_channel_open_session 失败: %{public}s",
                         errMsg ? errMsg : "unknown");
            return ERR_SSH_CHANNEL_OPEN;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SSH] 通道已打开");
    return 0;
}

int SshAdapter::requestPty(int cols, int rows) {
    if (!channel_) { return ERR_SSH_PTY_FAILED; }

    int rc;
    while ((rc = libssh2_channel_request_pty(channel_, "xterm-256color")) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 15);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] PTY 请求超时");
            return ERR_SSH_PTY_FAILED;
        }
    }
    if (rc) {
        OH_LOG_ERROR(LOG_APP, "[SSH] PTY 请求失败: rc=%{public}d", rc);
        return ERR_SSH_PTY_FAILED;
    }

    // 设置初始窗口大小
    libssh2_channel_request_pty_size(channel_, cols, rows);
    OH_LOG_INFO(LOG_APP, "[SSH] PTY 已分配 %{public}dx%{public}d (term=xterm-256color)", cols, rows);
    return 0;
}

int SshAdapter::startShell() {
    if (!channel_) { return ERR_SSH_SHELL_FAILED; }

    int rc;
    while ((rc = libssh2_channel_shell(channel_)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 15);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 启动 Shell 超时");
            return ERR_SSH_SHELL_FAILED;
        }
    }
    if (rc) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 启动 Shell 失败: rc=%{public}d", rc);
        return ERR_SSH_SHELL_FAILED;
    }
    OH_LOG_INFO(LOG_APP, "[SSH] Shell 已启动");
    return 0;
}

// ============================================================
// 连接管理 (完整 SSH2 流程)
// ============================================================

int SshAdapter::connect(const ConnectionConfig& cfg) {
    if (state_ == ConnectionState::CONNECTED) {
        OH_LOG_WARN(LOG_APP, "[SSH] 已连接, 先断开");
        disconnect();
    }

    // 保存配置 (用于后续认证和重连)
    savedCfg_ = cfg;

    setState(ConnectionState::CONNECTING);

    // Step 1: TCP 连接
    int ret = tcpConnect(cfg.host, cfg.port > 0 ? cfg.port : 22);
    if (ret < 0) {
        setState(ConnectionState::ERROR);
        return ret;
    }

    // Step 2: KEX 密钥交换 (libssh2内部处理Banner,无需手动预读)
    ret = sshHandshake();
    if (ret < 0) {
        disconnect();
        setState(ConnectionState::ERROR);
        return ret;
    }

    // Step 4: 用户认证 (公钥优先, 失败时回退密码)
    OH_LOG_INFO(LOG_APP, "[SSH] 认证方式=%{public}s", cfg.authMethod.c_str());
    if (cfg.authMethod == "publickey" && !cfg.privateKeyPem.empty()) {
        ret = authenticatePublicKey(cfg.username, cfg.privateKeyPem, cfg.privateKeyPassphrase);
        if (ret < 0 && !cfg.password.empty()) {
            OH_LOG_WARN(LOG_APP, "[SSH] 公钥认证失败, 回退到密码认证");
            ret = authenticatePassword();
        }
    } else {
        ret = authenticatePassword();
    }
    if (ret < 0) {
        disconnect();
        setState(ConnectionState::ERROR);
        return ret;
    }

    // Step 5: 打开 SSH 会话通道
    ret = openChannel();
    if (ret < 0) {
        disconnect();
        setState(ConnectionState::ERROR);
        return ret;
    }

    // Step 6: 请求 PTY (SSH 调用方将 cfg.width/height 传为终端 cols/rows)
    int ptyCols = cfg.width > 0 ? cfg.width : 80;
    int ptyRows = cfg.height > 0 ? cfg.height : 24;
    ret = requestPty(ptyCols, ptyRows);
    if (ret < 0) {
        disconnect();
        setState(ConnectionState::ERROR);
        return ret;
    }

    // Step 7: 启动远程 Shell
    ret = startShell();
    if (ret < 0) {
        disconnect();
        setState(ConnectionState::ERROR);
        return ret;
    }

    setState(ConnectionState::CONNECTED);
    const std::string logHost = SafeLog::MaskHost(cfg.host);
    OH_LOG_INFO(LOG_APP, "[SSH] SSH 连接建立完成 (libssh2 完整握手, %{public}s:%{public}d)",
                logHost.c_str(), cfg.port);

    // Step 8: 启动后台 reader 线程 (推送式数据回调; 替代 ArkTS 50ms 轮询)
    startReader();

    return 0;
}

void SshAdapter::disconnect() {
    // 先停 reader 线程, 避免后续 channel/session free 时的竞态
    stopReader();

    {
        std::lock_guard<std::mutex> callbackLock(callbackMutex_);
        onDataCallback_ = nullptr;
        pendingData_.clear();
    }

    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    if (sftp_) {
        libssh2_sftp_shutdown(sftp_);
        sftp_ = nullptr;
    }
    if (channel_) {
        libssh2_channel_free(channel_);
        channel_ = nullptr;
    }
    if (session_) {
        libssh2_session_disconnect(session_, "Client disconnecting");
        libssh2_session_free(session_);
        session_ = nullptr;
    }
    if (sockFd_ >= 0) {
        shutdown(sockFd_, SHUT_RDWR);
        close(sockFd_);
        sockFd_ = -1;
        OH_LOG_INFO(LOG_APP, "[SSH] TCP 连接已断开");
    }
    authenticated_ = false;
    setState(ConnectionState::DISCONNECTED);
}

ConnectionState SshAdapter::getState() {
    return state_;
}

// ============================================================
// 输入事件 (SSH 终端仅 sendText 有效)
// ============================================================

void SshAdapter::sendKey(uint32_t scancode, bool pressed) {
    // SSH 终端不直接处理按键扫描码, 通过 sendText 传递字符
    (void)scancode; (void)pressed;
}

void SshAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    (void)x; (void)y; (void)button; (void)pressed;
}

void SshAdapter::sendMouseWheel(int x, int y, int delta) {
    (void)x; (void)y; (void)delta;
}

void SshAdapter::sendText(const std::string& text) {
    sendData(reinterpret_cast<const uint8_t*>(text.c_str()), text.size());
}

// ============================================================
// 编码能力
// ============================================================

bool SshAdapter::supportsCodec(CodecType codec) {
    (void)codec;
    return false;
}

std::vector<CodecType> SshAdapter::supportedCodecs() {
    return {};
}

// ============================================================
// SFTP 文件传输
// ============================================================

int SshAdapter::ensureSftpLocked() {
    if (!session_ || state_ != ConnectionState::CONNECTED) {
        return ERR_SSH_SESSION_CLOSED;
    }
    if (sftp_) { return 0; }

    while ((sftp_ = libssh2_sftp_init(session_)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15);
            if (w != 0) {
                OH_LOG_ERROR(LOG_APP, "[SFTP] 初始化超时");
                return ERR_SSH_CHANNEL_OPEN;
            }
            continue;
        }
        char* errMsg = nullptr;
        libssh2_session_last_error(session_, &errMsg, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SFTP] 初始化失败: err=%{public}d msg=%{public}s",
                     err, errMsg ? errMsg : "");
        return ERR_SSH_CHANNEL_OPEN;
    }

    OH_LOG_INFO(LOG_APP, "[SFTP] 子系统已初始化");
    return 0;
}

int SshAdapter::sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) {
    if (remotePath.empty() || (data == nullptr && len > 0)) {
        return -1;
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }

    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(),
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15);
            if (w != 0) { return ERR_SSH_WRITE_FAILED; }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开远端写文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_WRITE_FAILED;
    }

    uint32_t total = 0;
    while (total < len) {
        size_t chunk = std::min<size_t>(32768, len - total);
        ssize_t written = libssh2_sftp_write(handle,
            reinterpret_cast<const char*>(data + total), chunk);
        if (written == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(1, 15);
            if (w != 0) {
                libssh2_sftp_close(handle);
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (written < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 写入失败: pathId=%{public}s ret=%{public}zd",
                         pathId.c_str(), written);
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
        total += static_cast<uint32_t>(written);
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        waitSocket(2, 5);
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 上传完成: pathId=%{public}s bytes=%{public}u rc=%{public}d",
                pathId.c_str(), len, rc);
    return rc == 0 ? static_cast<int>(len) : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::writeRemoteFileChunk(const std::string& remotePath, const uint8_t* data,
                                     uint32_t len, uint64_t offset, bool truncate) {
    if (remotePath.empty() || (data == nullptr && len > 0)) {
        return -1;
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }

    unsigned long flags = LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT;
    if (truncate) { flags |= LIBSSH2_FXF_TRUNC; }
    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(), flags,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15);
            if (w != 0) { return ERR_SSH_WRITE_FAILED; }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开分块写文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_WRITE_FAILED;
    }

    libssh2_sftp_seek64(handle, offset);
    uint32_t total = 0;
    while (total < len) {
        size_t chunk = std::min<size_t>(32768, len - total);
        ssize_t written = libssh2_sftp_write(handle,
            reinterpret_cast<const char*>(data + total), chunk);
        if (written == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(1, 15);
            if (w != 0) {
                libssh2_sftp_close(handle);
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (written < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 分块写入失败: pathId=%{public}s offset=%{public}llu ret=%{public}zd",
                         pathId.c_str(),
                         static_cast<unsigned long long>(offset + total),
                         written);
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
        total += static_cast<uint32_t>(written);
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        waitSocket(2, 5);
    }
    return rc == 0 ? static_cast<int>(total) : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::listRemoteDir(const std::string& remotePath, std::vector<SftpFileEntry>& entries) {
    entries.clear();
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }

    std::string dirPath = remotePath.empty() ? "." : remotePath;
    const std::string pathId = SafeLog::HashForLog(dirPath);
    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_opendir(sftp_, dirPath.c_str())) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15);
            if (w != 0) { return ERR_SSH_READ_FAILED; }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开目录失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_READ_FAILED;
    }

    while (true) {
        char nameBuf[4096] = {0};
        char longEntryBuf[4096] = {0};
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        memset(&attrs, 0, sizeof(attrs));
        int n = libssh2_sftp_readdir_ex(handle, nameBuf, sizeof(nameBuf) - 1,
            longEntryBuf, sizeof(longEntryBuf) - 1, &attrs);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            waitSocket(2, 5);
            continue;
        }
        if (n < 0) {
            OH_LOG_WARN(LOG_APP, "[SFTP] 读取目录中断: pathId=%{public}s ret=%{public}d",
                        pathId.c_str(), n);
            break;
        }
        if (n == 0) { break; }
        std::string name(nameBuf, static_cast<size_t>(n));
        if (name == "." || name == "..") { continue; }

        SftpFileEntry entry;
        entry.name = name;
        if (dirPath == "/" || dirPath.empty()) {
            entry.path = "/" + name;
        } else {
            entry.path = dirPath + "/" + name;
        }
        entry.isDirectory = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
            LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
        entry.size = (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) ? attrs.filesize : 0;
        entry.mtime = (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? attrs.mtime : 0;
        entries.push_back(entry);
    }

    while ((rc = libssh2_sftp_closedir(handle)) == LIBSSH2_ERROR_EAGAIN) {
        waitSocket(2, 5);
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 目录读取完成: pathId=%{public}s count=%{public}zu",
                pathId.c_str(), entries.size());
    return static_cast<int>(entries.size());
}

int SshAdapter::readRemoteFile(const std::string& remotePath, std::vector<uint8_t>& out) {
    out.clear();
    if (remotePath.empty()) { return -1; }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }

    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15);
            if (w != 0) { return ERR_SSH_READ_FAILED; }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开远端读文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_READ_FAILED;
    }

    std::vector<uint8_t> buf(32768);
    while (true) {
        ssize_t n = libssh2_sftp_read(handle, reinterpret_cast<char*>(buf.data()), buf.size());
        if (n == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(0, 15);
            if (w != 0) {
                libssh2_sftp_close(handle);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 读取文件失败: pathId=%{public}s ret=%{public}zd",
                         pathId.c_str(), n);
            libssh2_sftp_close(handle);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) { break; }
        out.insert(out.end(), buf.begin(), buf.begin() + n);
        if (out.size() > 100 * 1024 * 1024) {
            OH_LOG_WARN(LOG_APP, "[SFTP] 下载超过 100MB, 已中止: pathId=%{public}s", pathId.c_str());
            libssh2_sftp_close(handle);
            out.clear();
            return -2;
        }
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        waitSocket(2, 5);
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 下载完成: pathId=%{public}s bytes=%{public}zu rc=%{public}d",
                pathId.c_str(), out.size(), rc);
    return rc == 0 ? static_cast<int>(out.size()) : ERR_SSH_READ_FAILED;
}

int SshAdapter::readRemoteFileChunk(const std::string& remotePath, uint64_t offset,
                                    uint32_t maxLen, std::vector<uint8_t>& out) {
    out.clear();
    if (remotePath.empty() || maxLen == 0 || maxLen > 1024 * 1024) { return -1; }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }

    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15);
            if (w != 0) { return ERR_SSH_READ_FAILED; }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开远端分块读文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_READ_FAILED;
    }

    libssh2_sftp_seek64(handle, offset);
    std::vector<uint8_t> buf(std::min<uint32_t>(32768, maxLen));
    while (out.size() < maxLen) {
        const size_t remain = static_cast<size_t>(maxLen) - out.size();
        const size_t want = std::min(buf.size(), remain);
        ssize_t n = libssh2_sftp_read(handle, reinterpret_cast<char*>(buf.data()), want);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(0, 15);
            if (w != 0) {
                libssh2_sftp_close(handle);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 分块读取文件失败: pathId=%{public}s offset=%{public}llu ret=%{public}zd",
                         pathId.c_str(),
                         static_cast<unsigned long long>(offset + out.size()),
                         n);
            libssh2_sftp_close(handle);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) { break; }
        out.insert(out.end(), buf.begin(), buf.begin() + n);
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        waitSocket(2, 5);
    }
    return rc == 0 ? static_cast<int>(out.size()) : ERR_SSH_READ_FAILED;
}

int SshAdapter::removeRemoteFile(const std::string& remotePath) {
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_unlink(sftp_, remotePath.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 10);
        if (w != 0) { return ERR_SSH_WRITE_FAILED; }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 删除文件: pathId=%{public}s rc=%{public}d", pathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::removeRemoteDir(const std::string& remotePath) {
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_rmdir(sftp_, remotePath.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 10);
        if (w != 0) { return ERR_SSH_WRITE_FAILED; }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 删除目录: pathId=%{public}s rc=%{public}d", pathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::makeRemoteDir(const std::string& remotePath) {
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_mkdir(sftp_, remotePath.c_str(),
        LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP |
        LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 10);
        if (w != 0) { return ERR_SSH_WRITE_FAILED; }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 创建目录: pathId=%{public}s rc=%{public}d", pathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::renameRemotePath(const std::string& oldPath, const std::string& newPath) {
    const std::string oldPathId = SafeLog::HashForLog(oldPath);
    const std::string newPathId = SafeLog::HashForLog(newPath);
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked();
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_rename(sftp_, oldPath.c_str(), newPath.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 10);
        if (w != 0) { return ERR_SSH_WRITE_FAILED; }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 重命名: %{public}s -> %{public}s rc=%{public}d",
                oldPathId.c_str(), newPathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

// ============================================================
// 回调
// ============================================================

void SshAdapter::setVideoCallback(VideoFrameCallback callback) {
    (void)callback;
}

void SshAdapter::setAudioCallback(AudioDataCallback callback) {
    (void)callback;
}

void SshAdapter::setConnectionStateCallback(ConnectionStateCallback callback) {
    stateCallback_ = callback;
}

// ============================================================
// SSH 终端数据读写 (加密通道)
// ============================================================

int SshAdapter::sendData(const uint8_t* data, size_t len) {
    if (!channel_ || state_ != ConnectionState::CONNECTED) {
        return -1;
    }
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    ssize_t total = 0;
    while (total < static_cast<ssize_t>(len)) {
        ssize_t rc = libssh2_channel_write(channel_,
            reinterpret_cast<const char*>(data) + total, len - total);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            waitSocket(1, 1); // 100ms implicit via 1s timeout
            continue;
        }
        if (rc < 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_channel_write 失败: %{public}zd", rc);
            return ERR_SSH_WRITE_FAILED;
        }
        total += rc;
    }
    return static_cast<int>(total);
}

int SshAdapter::readData(uint8_t* buf, size_t bufSize) {
    if (!channel_ || state_ != ConnectionState::CONNECTED) {
        return -1;
    }

    // 非阻塞快速轮询 (50ms)
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(sockFd_, &rfds);
    struct timeval tv = {0, 50000};
    int ret = select(sockFd_ + 1, &rfds, nullptr, nullptr, &tv);
    if (ret <= 0) { return 0; }

    // 从加密通道读取 (可能解密后返回 EAGAIN 即使 socket 可读)
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    ssize_t n = libssh2_channel_read(channel_, reinterpret_cast<char*>(buf), bufSize);
    if (n == LIBSSH2_ERROR_EAGAIN) {
        return 0;
    }
    if (n < 0) {
        OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_channel_read 失败: %{public}zd", n);
        return ERR_SSH_READ_FAILED;
    }
    if (n == 0) {
        // 通道 EOF
        OH_LOG_INFO(LOG_APP, "[SSH] 远程关闭通道 (EOF)");
        setState(ConnectionState::DISCONNECTED);
        return ERR_SSH_SESSION_CLOSED;
    }
    return static_cast<int>(n);
}

void SshAdapter::resizePty(int cols, int rows) {
    if (channel_) {
        std::lock_guard<std::mutex> sessionLock(sessionMutex_);
        int rc = libssh2_channel_request_pty_size(channel_, cols, rows);
        if (rc == 0) {
            OH_LOG_INFO(LOG_APP, "[SSH] PTY 尺寸已调整: %{public}dx%{public}d", cols, rows);
        } else {
            OH_LOG_WARN(LOG_APP, "[SSH] PTY 尺寸调整失败: rc=%{public}d", rc);
        }
    } else {
        OH_LOG_WARN(LOG_APP, "[SSH] resizePty 失败: 通道未打开");
    }
}

int SshAdapter::getSocketFd() const {
    return sockFd_;
}

int SshAdapter::measureLatencyMs() {
    if (!session_ || state_ != ConnectionState::CONNECTED) {
        return -1;
    }
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    auto start = std::chrono::steady_clock::now();
    int secondsToNext = 0;
    int rc = LIBSSH2_ERROR_EAGAIN;
    while ((rc = libssh2_keepalive_send(session_, &secondsToNext)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 3);
        if (w != 0) {
            OH_LOG_WARN(LOG_APP, "[SSH] keepalive 等待超时: wait=%{public}d", w);
            return -2;
        }
    }
    if (rc != 0) {
        OH_LOG_WARN(LOG_APP, "[SSH] keepalive 失败: rc=%{public}d", rc);
        return -3;
    }
    auto end = std::chrono::steady_clock::now();
    return static_cast<int>(
        std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count());
}

// ============================================================
// 推送式数据回调 (后台 reader 线程)
// ============================================================

void SshAdapter::setOnDataCallback(DataCallback cb) {
    std::lock_guard<std::mutex> lk(callbackMutex_);
    onDataCallback_ = std::move(cb);
    if (!onDataCallback_) {
        pendingData_.clear();
    }
    OH_LOG_INFO(LOG_APP, "[SSH] onDataCallback %{public}s",
                onDataCallback_ ? "已注册" : "已清除");
}

void SshAdapter::startReader() {
    if (readerRunning_.load()) { return; }
    readerRunning_.store(true);
    readerThread_ = std::thread(&SshAdapter::readerLoop, this);
    OH_LOG_INFO(LOG_APP, "[SSH] reader 线程已启动");
}

void SshAdapter::stopReader() {
    if (!readerRunning_.load()) {
        if (readerThread_.joinable()) { readerThread_.join(); }
        return;
    }
    readerRunning_.store(false);
    if (readerThread_.joinable()) {
        readerThread_.join();
    }
    OH_LOG_INFO(LOG_APP, "[SSH] reader 线程已退出");
}

void SshAdapter::readerLoop() {
    constexpr size_t kBufSize = SSH_BUFFER_SIZE;
    constexpr size_t kMaxPendingData = SSH_BUFFER_SIZE * 4;
    std::vector<uint8_t> buf(kBufSize);

    while (readerRunning_.load()) {
        // 拷贝必要句柄, 避免在 select 期间 disconnect 修改它们
        int fd = sockFd_;
        LIBSSH2_CHANNEL* ch = channel_;
        if (fd < 0 || ch == nullptr || state_ != ConnectionState::CONNECTED) {
            // 句柄无效, 短暂休眠后再判断 (避免 busy-loop)
            struct timeval tv = {0, 100 * 1000};  // 100ms
            select(0, nullptr, nullptr, nullptr, &tv);
            continue;
        }

        // connect() 会先启动 reader, ArkTS 只能在 connect() 返回后注册回调。
        // 把这段空窗期收到的登录 banner 延迟到回调就绪后再发送，避免首次连接丢首屏。
        DataCallback pendingCb;
        std::string pending;
        {
            std::lock_guard<std::mutex> lk(callbackMutex_);
            if (onDataCallback_ && !pendingData_.empty()) {
                pendingCb = onDataCallback_;
                pending.swap(pendingData_);
            }
        }
        if (pendingCb && !pending.empty()) {
            try { pendingCb(pending); } catch (...) { /* 静默, 不中断 reader */ }
        }

        // 100ms select 等待 socket 可读
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv = {0, 100 * 1000};  // 100ms
        int sret = select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (sret < 0) {
            if (errno == EINTR) { continue; }
            OH_LOG_WARN(LOG_APP, "[SSH] reader select 错误: errno=%{public}d", errno);
            break;
        }
        if (sret == 0) { continue; }  // 超时, 继续循环

        // 反复读直到 EAGAIN, 减少 select 次数 (大输出场景)
        bool gotData = false;
        std::string accumulated;
        accumulated.reserve(kBufSize * 2);
        while (readerRunning_.load()) {
            std::lock_guard<std::mutex> sessionLock(sessionMutex_);
            ssize_t n = libssh2_channel_read(ch, reinterpret_cast<char*>(buf.data()), kBufSize);
            if (n == LIBSSH2_ERROR_EAGAIN) { break; }
            if (n < 0) {
                OH_LOG_ERROR(LOG_APP, "[SSH] reader libssh2_channel_read 失败: %{public}zd", n);
                readerRunning_.store(false);
                break;
            }
            if (n == 0) {
                // EOF: 远程关闭
                OH_LOG_INFO(LOG_APP, "[SSH] reader 检测到 EOF, 通道关闭");
                setState(ConnectionState::DISCONNECTED);
                readerRunning_.store(false);
                break;
            }
            accumulated.append(reinterpret_cast<const char*>(buf.data()),
                              static_cast<size_t>(n));
            gotData = true;
            // 单批最多 256KB, 防止极端场景占用过多内存
            if (accumulated.size() >= kBufSize * 4) { break; }
        }

        if (gotData && !accumulated.empty()) {
            DataCallback cb;
            std::string dataToDeliver;
            {
                std::lock_guard<std::mutex> lk(callbackMutex_);
                if (onDataCallback_) {
                    cb = onDataCallback_;
                    dataToDeliver.swap(pendingData_);
                    dataToDeliver.append(accumulated);
                } else {
                    pendingData_.append(accumulated);
                    if (pendingData_.size() > kMaxPendingData) {
                        pendingData_.erase(0, pendingData_.size() - kMaxPendingData);
                    }
                }
            }
            if (cb) {
                try { cb(dataToDeliver); } catch (...) { /* 静默, 不中断 reader */ }
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "[SSH] readerLoop 结束");
}

// ============================================================
// 注册到 ExtensionSystem
// ============================================================

void registerSshAdapter() {
    auto adapter = std::shared_ptr<SshAdapter>(new SshAdapter());
    ExtensionSystem::instance().protocols.registerExt("protocol", "ssh", adapter);
    OH_LOG_INFO(LOG_APP, "[SSH] SSH 适配器已注册 (libssh2 集成版 v%{public}s)", SSH_ADAPTER_VERSION);
}

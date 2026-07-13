/**
 * ssh_adapter.h — SSH 终端协议适配器 (libssh2 集成版)
 *
 * 基于 libssh2 + OpenSSL 的完整 SSH2 协议实现.
 * 支持密码认证和公钥认证, PTY 分配, Shell 会话, 窗口调整.
 */
#ifndef SSH_ADAPTER_H
#define SSH_ADAPTER_H

#include "protocol_adapter.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <string>
#include <functional>
#include <thread>
#include <atomic>
#include <mutex>
#include <sys/select.h>

#define SSH_ADAPTER_VERSION "2.0.0"
#define SSH_BUFFER_SIZE 65536

// ============================================================
// SSH 适配器错误码 (可追溯报错, 对照 hilog)
// ============================================================

enum SshError {
    ERR_SSH_SUCCESS             =  0,

    // TCP 层 (-1x)
    ERR_SSH_SOCKET_CREATE       = -11,
    ERR_SSH_SOCKET_CONNECT      = -12,
    ERR_SSH_CONNECT_TIMEOUT     = -13,
    ERR_SSH_DNS_RESOLVE         = -14,
    ERR_SSH_BANNER_INVALID      = -15,

    // SSH 协议层 (-2x)
    ERR_SSH_SESSION_INIT        = -21,
    ERR_SSH_KEX_FAILED          = -22,
    ERR_SSH_KEX_TIMEOUT         = -23,
    ERR_SSH_HOSTKEY_MISMATCH    = -24,

    // 认证层 (-3x)
    ERR_SSH_AUTH_FAILED         = -31,
    ERR_SSH_AUTH_TIMEOUT        = -32,
    ERR_SSH_AUTH_METHODS        = -33,
    ERR_SSH_AUTH_PARTIAL        = -34,

    // 通道层 (-4x)
    ERR_SSH_CHANNEL_OPEN        = -41,
    ERR_SSH_CHANNEL_CLOSED      = -42,
    ERR_SSH_PTY_FAILED          = -43,
    ERR_SSH_SHELL_FAILED        = -44,

    // 数据传输层 (-5x)
    ERR_SSH_READ_FAILED         = -51,
    ERR_SSH_WRITE_FAILED        = -52,
    ERR_SSH_SESSION_CLOSED      = -53,
};

class SshAdapter : public ProtocolAdapter {
public:
    SshAdapter();
    virtual ~SshAdapter();

    // ---- ProtocolAdapter 接口 ----
    std::string protocolName() override;
    int defaultPort() override;
    std::string protocolVersion() override;

    int connect(const ConnectionConfig& cfg) override;
    void disconnect() override;
    ConnectionState getState() override;

    void sendKey(uint32_t scancode, bool pressed) override;
    void sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void sendMouseWheel(int x, int y, int delta) override;
    void sendText(const std::string& text) override;

    bool supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;

    void setVideoCallback(VideoFrameCallback callback) override;
    void setAudioCallback(AudioDataCallback callback) override;
    void setConnectionStateCallback(ConnectionStateCallback callback) override;

    bool supportsNatTraversal() override { return false; }
    bool supportsFileTransfer() override { return true; }

    // ---- SSH 终端专用方法 ----

    /** 写入终端数据 (通过加密通道发送) */
    int sendData(const uint8_t* data, size_t len);

    /** 读取终端输出 (非阻塞, 返回读取字节数; 0=无数据; -1=通道关闭) */
    int readData(uint8_t* buf, size_t bufSize);

    /** 调整 PTY 窗口大小 */
    void resizePty(int cols, int rows);

    /** SSH keepalive 往返检测, 返回耗时 ms; 负数表示失败 */
    int measureLatencyMs();

    /** 获取 socket fd (用于 select/poll 轮询) */
    int getSocketFd() const;

    // ---- 认证方法 (供 NAPI 调用) ----

    /** 公钥认证 (PEM 格式私钥, 临时明文, 调用后应立即擦除) */
    int authenticatePublicKey(const std::string& username,
                              const std::string& privateKeyPem,
                              const std::string& passphrase = "");

    // ---- 推送式数据回调 (替代 50ms 轮询) ----

    using DataCallback = std::function<void(const std::string&)>;

    /** 设置推送回调 — 后台 reader 线程读到数据后立即调用. nullptr 关闭推送. */
    void setOnDataCallback(DataCallback cb);

    // ---- SFTP 文件传输 ----
    int sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) override;
    int writeRemoteFileChunk(const std::string& remotePath, const uint8_t* data,
                             uint32_t len, uint64_t offset, bool truncate) override;
    int listRemoteDir(const std::string& remotePath, std::vector<SftpFileEntry>& entries) override;
    int readRemoteFile(const std::string& remotePath, std::vector<uint8_t>& out) override;
    int readRemoteFileChunk(const std::string& remotePath, uint64_t offset,
                            uint32_t maxLen, std::vector<uint8_t>& out) override;
    int removeRemoteFile(const std::string& remotePath) override;
    int removeRemoteDir(const std::string& remotePath) override;
    int makeRemoteDir(const std::string& remotePath) override;
    int renameRemotePath(const std::string& oldPath, const std::string& newPath) override;

private:
    int sockFd_;
    ConnectionState state_;
    ConnectionStateCallback stateCallback_;
    std::string serverBanner_;
    bool authenticated_;

    // ---- libssh2 会话和通道 ----
    LIBSSH2_SESSION* session_;
    LIBSSH2_CHANNEL* channel_;
    LIBSSH2_SFTP* sftp_;
    ConnectionConfig savedCfg_;

    void setState(ConnectionState s);

    // exchangeBanner() 已移除 — libssh2 内部处理 banner

    /** POSIX socket 连接 */
    int tcpConnect(const std::string& host, int port);

    // ---- SSH 协议方法 (libssh2 集成) ----

    /** KEX 密钥交换 + 主机密钥验证 */
    int sshHandshake();

    /** 密码认证 */
    int authenticatePassword();

    /** 打开 SSH 会话通道 */
    int openChannel();

    /** 请求 PTY (终端类型 + 初始尺寸) */
    int requestPty(int cols, int rows);

    /** 启动远程 Shell */
    int startShell();

    /** 非阻塞等待并重试 libssh2 操作 (0=读 1=写) */
    int waitSocket(int direction, int timeoutSec);

    // ---- 后台 reader 线程 (推送式) ----
    std::thread        readerThread_;
    std::atomic<bool>  readerRunning_{false};
    DataCallback       onDataCallback_;
    std::mutex         callbackMutex_;          // 保护 onDataCallback_
    std::mutex         sessionMutex_;           // 串行化 libssh2 session/channel 操作

    /** 后台循环: select(100ms) → libssh2_channel_read → cb(data) */
    void readerLoop();

    /** 启动 / 停止 reader 线程 */
    void startReader();
    void stopReader();

    /** 确保 SFTP 子系统已初始化。调用方必须持有 sessionMutex_。 */
    int ensureSftpLocked();
};

/** 注册到 ExtensionSystem */
void registerSshAdapter();

#endif // SSH_ADAPTER_H

/**
 * ssh_adapter.h — SSH 终端协议适配器 (libssh2 集成版)
 *
 * 基于 libssh2 + OpenSSL 的完整 SSH2 协议实现.
 * 支持密码认证和公钥认证, PTY 分配, Shell 会话, 窗口调整.
 */
#ifndef SSH_ADAPTER_H
#define SSH_ADAPTER_H

#include "protocol_adapter.h"
#include "ssh_error.h"
#include "ssh_forward_target_connector.h"
#include "ssh_terminal_diagnostics.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <string>
#include <functional>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <utility>
#include <type_traits>
#include <chrono>
#include <sys/select.h>
#include <vector>
#include "ssh_terminal_input_queue_policy.h"
#include "ssh_terminal_keepalive_policy.h"
#include "ssh_pty_recovery_policy.h"
#include "ssh_forwarding_manager.h"
#include "ssh_route_policy.h"
#include "ssh_auth_prompt_broker.h"
#include "ssh_keyboard_interactive_route_admission.h"
#include "ssh_reconnect_policy.h"
#include "ssh_session_types.h"
#include "common/network_generation_fence.h"

#define SSH_ADAPTER_VERSION "2.0.0"
#define SSH_BUFFER_SIZE 65536

struct SftpOperationResult {
    int errorCode = ERR_SSH_REACTOR_QUEUE_FULL;
    bool transportLost = false;
};

struct SshCommandResult {
    int exitCode = -1;
    bool signaled = false;
    std::string signal;
    std::vector<uint8_t> stdoutBytes;
    std::vector<uint8_t> stderrBytes;
};

/**
 * Host-key material captured by an auxiliary SSH operation after KEX.
 * The snapshot never contains credentials and is valid only for the exact
 * production route used by connectForOperation().
 */
struct SshOperationHostKeySnapshot {
    bool ok = false;
    std::string algorithm;
    std::string fingerprintSha256;
    std::string rawBase64;
    std::string serverBanner;
};

enum class SshOperationSessionMode {
    ProbeOnly,
    Authenticated,
};

enum class SshTerminalInputStatus {
    ACCEPTED,
    QUEUE_FULL,
    SESSION_CLOSED,
    STALE_GENERATION,
    INVALID,
};

struct SshTerminalInputResult {
    SshTerminalInputStatus status = SshTerminalInputStatus::INVALID;
    uint64_t sequence = 0;
    uint64_t generation = 0;
    uint64_t queueDepth = 0;
    uint64_t queueBytes = 0;

    bool accepted() const noexcept {
        return status == SshTerminalInputStatus::ACCEPTED;
    }
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
    /**
     * Establish the production SSH transport without allocating a PTY/shell.
     * ProbeOnly stops after KEX; Authenticated verifies the target host key and
     * authenticates before returning. The caller must disconnect the adapter.
     */
    int connectForOperation(const ConnectionConfig& cfg,
                            SshOperationSessionMode mode,
                            remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
                            SshOperationHostKeySnapshot& hostKey,
                            std::chrono::steady_clock::time_point deadline);
    void disconnect() override;
    ConnectionState getState() override;

    /** 请求取消尚未完成的 SSH 连接；不会阻塞调用线程。 */
    void requestConnectCancel();

    void sendKey(uint32_t scancode, bool pressed) override;
    void sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void sendMouseWheel(int x, int y, int delta) override;
    void sendText(const std::string& text) override;

    bool supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;

    void setVideoCallback(VideoFrameCallback callback) override;
    void setAudioCallback(AudioDataCallback callback) override;
    void setConnectionStateCallback(ConnectionStateCallback callback) override;
    using SshLifecycleStateCallback =
        std::function<void(SshSessionLifecycleState, const std::string&)>;
    /** Receives lifecycle states with no lossy ConnectionState mapping. */
    void setSshLifecycleStateCallback(SshLifecycleStateCallback callback);
    void setSessionIdentity(uint64_t sessionId) override;
    void setSessionGeneration(uint64_t generation);

    /** Platform network availability event, fenced by its monotonic generation. */
    void onNetworkChanged(bool available, uint64_t networkGeneration) override;

    // Forwarding profiles are owned by this SSH adapter. Runtime transitions
    // are serialized through the same session-owner reactor as libssh2.
    SshForwardingResult configureForwarding(const SshForwardingConfig& config);
    SshForwardingResult removeForwarding(const std::string& id);
    SshForwardingResult startForwarding(const std::string& id,
                                        uint64_t expectedGeneration);
    SshForwardingResult markForwardingListening(const std::string& id,
                                                uint64_t expectedGeneration);
    SshForwardingResult failForwarding(const std::string& id,
                                       uint64_t expectedGeneration, int error);
    SshForwardingResult requestForwardingStop(const std::string& id,
                                              uint64_t expectedGeneration);
    SshForwardingResult completeForwardingStop(const std::string& id,
                                               uint64_t expectedGeneration);
    SshForwardingResult acquireForwardingConnection(const std::string& id,
                                                    uint64_t expectedGeneration);
    SshForwardingResult releaseForwardingConnection(const std::string& id,
                                                    uint64_t expectedGeneration);
    std::vector<SshForwardingSnapshot> forwardingSnapshots() const;

    bool supportsNatTraversal() override { return false; }
    bool supportsFileTransfer() override { return true; }

    // ---- SSH 终端专用方法 ----

    /** 写入终端数据 (通过加密通道发送) */
    int sendData(const uint8_t* data, size_t len);

    /** 非阻塞地把终端输入交给 SSH writer。control 输入使用保留容量。 */
    SshTerminalInputResult enqueueTerminalInput(const uint8_t* data, size_t len,
                                                bool control, uint64_t expectedGeneration,
                                                bool ordered = false, bool orderedEnd = false);
    /** Reject new terminal input before asynchronous session teardown begins. */
    void rejectTerminalInput();

    /** 读取终端输出 (非阻塞, 返回读取字节数; 0=无数据; -1=通道关闭) */
    int readData(uint8_t* buf, size_t bufSize);

    /** 调整 PTY 窗口大小 */
    void resizePty(int cols, int rows);

    /** SSH keepalive 往返检测, 返回耗时 ms; 负数表示失败 */
    int measureLatencyMs();

    /** 获取 socket fd (用于 select/poll 轮询) */
    int getSocketFd() const;

    /** 返回不含终端 payload 的 SSH 输入/输出诊断快照。 */
    SshTerminalDiagnosticsSnapshot terminalDiagnostics() const;
    /** TSFN producer reports the result of the bounded callback enqueue. */
    void recordTerminalCallbackAccepted(size_t byteCount);
    void recordTerminalCallbackQueueFull();
    void recordTerminalCallbackDeliveryError(bool closing);
    void markTerminalCallbackInstrumentation();
    /** Fail closed when the JS output consumer cannot preserve terminal bytes. */
    void failTerminalOutput(const std::string& reason);

    // ---- 认证方法 (供 NAPI 调用) ----

    /** 公钥认证 (PEM 格式私钥, 临时明文, 调用后应立即擦除) */
    int authenticatePublicKey(const std::string& username,
                              const std::string& privateKeyPem,
                              const std::string& passphrase = "");

    /** 使用 keyboard-interactive 认证，支持预置 MFA/OTP 响应。 */
    int authenticateKeyboardInteractive(bool allowPasswordFallback = false);

    /** Read the current one-shot keyboard-interactive prompt, if any. */
    bool getAuthPrompt(SshAuthPromptRequest& out) const;
    bool respondAuthPrompt(SshAuthPromptResponse response);
    bool cancelAuthPrompt(uint64_t requestId, uint64_t expectedGeneration);

    /** Internal libssh2 callback bridge shared by target and jump auth. */
    int fillKeyboardInteractiveResponses(
        const char* name, int nameLen, const char* instruction, int instructionLen,
        int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
        LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses,
        int transportFd,
        std::vector<std::string>* explicitResponses,
        const std::string* password, bool allowPasswordFallback,
        const std::string& targetHost, const std::string& hop,
        size_t& presetIndex, bool& passwordFallbackUsed);
    void recordAuthPromptFailure(int error) noexcept;

    /** Explicit SSH session identity used by background/UI facades. */
    SshSessionSnapshot sessionSnapshot() const;
    SshSessionLifecycleState sessionLifecycleState() const noexcept {
        return sshLifecycleState_.load(std::memory_order_acquire);
    }

    /** 在独立 SSH channel 上执行命令，不影响交互式 Shell。 */
    int executeCommand(const std::string& command, SshCommandResult& result,
                       int timeoutMs = 30000);

    /**
     * Execute the idempotent auxiliary-operation command only if its exact
     * admission generation still owns this transport.
     */
    int executeCommandForOperation(
        const std::string& command, SshCommandResult& result,
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
        int timeoutMs = 30000);

    /** 在独立 SSH channel 上启动 subsystem 并收集其输出。 */
    int executeSubsystem(const std::string& subsystem, SshCommandResult& result,
                         int timeoutMs = 30000);

    /** 向交互式 Shell channel 发送 SSH signal / EOF。 */
    int sendChannelSignal(const std::string& signal);
    int sendChannelEof();

    // ---- 推送式数据回调 (替代 50ms 轮询) ----

    using DataCallback = std::function<void(const std::vector<uint8_t>&)>;

    /** 设置推送回调 — 后台 reader 线程读到数据后立即调用. nullptr 关闭推送. */
    void setOnDataCallback(DataCallback cb);
    /** Detach the consumer without stopping the session owner reactor. */
    void detachOnDataCallback();
    /** Return a callback queued for a detached page to the live session FIFO. */
    void redeliverTerminalOutputAfterDetach(const std::vector<uint8_t>& data);
    /** Suspend/resume terminal input while a page view is detached. */
    void suspendTerminalInput();
    void resumeTerminalInput();

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
    /** OpenSSH POSIX rename used only for an integrity-checked commit. */
    int renameRemotePathAtomic(const std::string& oldPath, const std::string& newPath);
    /** Run and classify one complete SFTP operation in a single owner command. */
    SftpOperationResult executeSftpOperation(const std::function<int()>& operation);
    /** Classify a failed SFTP operation on the owner reactor before N-API resolves it. */
    bool classifySftpTransportFailure(int operationError);

private:
    struct LocalForwardListener {
        std::string profileId;
        uint64_t sessionGeneration = 0;
        SshForwardingMode mode = SshForwardingMode::Local;
        int fd = -1;
        LIBSSH2_LISTENER* remoteListener = nullptr;
        std::string boundHost;
        int boundPort = 0;
        int boundFamily = 0;
    };

    struct LocalForwardConnection {
        std::string profileId;
        uint64_t sessionGeneration = 0;
        SshForwardingMode mode = SshForwardingMode::Local;
        int localFd = -1;
        LIBSSH2_CHANNEL* channel = nullptr;
        bool localConnecting = false;
        SshForwardTargetConnectTask targetConnectTask;
        bool localEof = false;
        bool channelEof = false;
        bool channelEofSent = false;
        bool localWriteShutdown = false;
        bool closeAfterLocalFlush = false;
        bool socksGreetingComplete = false;
        bool socksRequestComplete = false;
        bool socksConnectResponseQueued = false;
        std::string dynamicTargetHost;
        int dynamicTargetPort = 0;
        std::vector<uint8_t> socksInput;
        std::vector<uint8_t> toChannel;
        std::vector<uint8_t> toLocal;
    };

    int connectInternal(const ConnectionConfig& cfg, bool preserveOwner = false);
    int connectForOperationInternal(const ConnectionConfig& cfg,
                                    SshOperationSessionMode mode,
                                    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
                                    SshOperationHostKeySnapshot& hostKey,
                                    std::chrono::steady_clock::time_point deadline);
    int authenticateConfiguredUser(const ConnectionConfig& cfg);
    void resetTransportForRecovery();
    bool reconnectAfterTransportFailure();
    bool assertSessionOwner(const char* operation) const noexcept;
    void setSshLifecycleState(SshSessionLifecycleState state,
                              const std::string& eventType = "");
    int keyboardInteractiveResponseRound(
        const char* name, int nameLen, const char* instruction, int instructionLen,
        int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
        LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses);

    int sockFd_;
    // Incremented whenever the socket/channel ownership changes. Reader
    // snapshots this before poll and revalidates it after reacquiring the
    // session lock, so fd reuse cannot turn a stale poll into a channel read.
    std::atomic<uint64_t> ioGeneration_{0};
    std::atomic<ConnectionState> state_;
    ConnectionStateCallback stateCallback_;
    std::string serverBanner_;
    bool authenticated_;
    // Non-secret method list returned by libssh2_userauth_list. It controls
    // password -> keyboard-interactive fallback for PAM-style servers.
    std::string advertisedAuthMethods_;
    std::atomic<SshSessionLifecycleState> sshLifecycleState_ {
        SshSessionLifecycleState::Created};
    std::atomic<uint64_t> sshEventSequence_ {0};
    std::atomic<int> authPromptFailure_ {0};
    SshAuthPromptBroker authPromptBroker_;
    std::string authPromptHop_ = "target";
    bool authPromptAllowPasswordFallback_ = false;
    size_t authPromptPresetIndex_ = 0;
    bool authPromptPasswordFallbackUsed_ = false;
    // Set only when an explicit KBI/OTP answer is handed to libssh2. The bit
    // survives route and transport failures so no automatic path can submit
    // that answer to a second SSH session; a user-initiated connect resets it.
    std::atomic<bool> explicitAuthResponseConsumed_{false};
    // The initial request and callback response are separate admission
    // phases so a blocking MFA prompt never pins the process network fence.
    SshKeyboardInteractiveRouteAdmission authRouteAdmission_;

    // ---- libssh2 会话和通道 ----
    LIBSSH2_SESSION* session_;
    LIBSSH2_CHANNEL* channel_;
    LIBSSH2_SFTP* sftp_;
    // Each ProxyJump hop owns an independent libssh2 session and an optional
    // direct-tcpip channel to the next hop/target. The relay thread is the
    // sole owner of these channels after setup; the target session sees only
    // the final socketpair endpoint in sockFd_.
    struct JumpHopRuntime {
        LIBSSH2_SESSION* session = nullptr;
        LIBSSH2_CHANNEL* channel = nullptr;
        int transportFd = -1;
        int channelPeerFd = -1;
    };
    std::mutex jumpRuntimeMutex_;
    std::vector<JumpHopRuntime> jumpHopRuntimes_;
    std::thread jumpRelayThread_;
    std::atomic<bool> jumpRelayRunning_{false};
    std::atomic<bool> jumpRelayStopRequested_{false};
    // Serializes SFTP handle ownership and gives disconnect a stable outer
    // lifetime fence while individual network slices release sessionMutex_.
    std::mutex sftpOperationMutex_;
    ConnectionConfig savedCfg_;
    SshForwardingManager forwardingManager_;
    std::map<std::string, LocalForwardListener> localForwardListeners_;
    std::vector<LocalForwardConnection> localForwardConnections_;
    // Accepted remote-forward channels that could not finish an admitted
    // non-blocking free are retained here and retried by the reactor. A raw
    // pointer must never be dropped on EAGAIN because libssh2 still owns it.
    std::vector<LIBSSH2_CHANNEL*> deferredForwardChannelCloses_;
    int lastPtyLibssh2Error_ = 0;
    SshPtyFailureClass lastPtyFailureClass_ = SshPtyFailureClass::NONE;

    void setState(ConnectionState s, const std::string& message = "");
    /** Publish the legacy connection state without replacing a richer SSH lifecycle state. */
    void setConnectionStateOnly(ConnectionState s, const std::string& message);

    // exchangeBanner() 已移除 — libssh2 内部处理 banner

    /** POSIX socket 连接 */
    int tcpConnect(const std::string& host, int port);

    /** 在已连接的代理 socket 上完成 HTTP CONNECT/SOCKS5 握手。 */
    int connectThroughProxy(ConnectionConfig& cfg);
    int connectThroughSshJump(ConnectionConfig& cfg);
    void sshJumpRelayLoop();
    void stopSshJumpRelay();
    int waitSocketOnFd(int fd, int direction, int timeoutSec);
    int sendSocketBytes(const uint8_t* data, size_t len, int timeoutSec);
    int receiveSocketBytes(uint8_t* data, size_t len, int timeoutSec);
    int receiveProxyHeaders(std::string& headers, size_t maxLen, int timeoutSec);

    // All forwarding modes are owned by the same reactor as the terminal
    // session. Local/dynamic use a local listener; remote uses a libssh2
    // remote listener and relays its accepted channels to a local target.
    int createLocalForwardListener(const SshForwardingConfig& config,
                                   std::string& boundHost, int& boundPort,
                                   int& boundFamily, int& errorCode);
    LIBSSH2_LISTENER* createRemoteForwardListener(const SshForwardingConfig& config,
                                                  int& boundPort, int& errorCode);
    int pumpDynamicSocksHandshakeLocked(LocalForwardConnection& connection);
    bool queueDynamicSocksFailureLocked(LocalForwardConnection& connection,
                                        uint8_t replyCode);
    int openLocalForwardChannelLocked(LocalForwardConnection& connection,
                                      const SshForwardingConfig& config);
    bool pumpLocalForwardConnectionLocked(LocalForwardConnection& connection,
                                           const SshForwardingConfig& config);
    void serviceForwardingOnReactor();
    bool tryFreeConnectedForwardChannelLocked(LIBSSH2_CHANNEL*& channel);
    void deferForwardChannelCloseLocked(LIBSSH2_CHANNEL* channel);
    bool closeLocalForwardConnectionLocked(LocalForwardConnection& connection);
    void closeLocalForwardRuntimeLocked(const std::string& id);

    struct TransportTeardownContext {
        std::chrono::steady_clock::time_point deadline;
        bool transportRetired = false;
    };
    void retirePrimaryTransportNoWireLocked(
        TransportTeardownContext& context) noexcept;
    int runTransportTeardownPrimitiveLocked(
        TransportTeardownContext& context,
        const std::function<int()>& primitive);
    void teardownAllForwardingRuntimeLocked(
        TransportTeardownContext& context);
    void teardownSessionHandlesLocked(const char* description);

    // ---- SSH 协议方法 (libssh2 集成) ----

    /** KEX 密钥交换 + 主机密钥验证 */
    int sshHandshake();

    /** 验证指定 SSH endpoint 的 host key；ProxyJump 跳板机要求必须有预期 key。 */
    int verifyHostKey(LIBSSH2_SESSION* session, const std::string& expectedRawBase64,
                      const std::string& expectedFingerprintSha256, bool required,
                      const char* endpointLabel, const std::string& endpointHost,
                      int endpointPort, int hopIndex);

    /** 密码认证 */
    int authenticatePassword();

    /** keyboard-interactive 认证回调 */
    static void keyboardInteractiveCallback(
        const char* name, int nameLen, const char* instruction, int instructionLen,
        int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
        LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses, void** abstract);
    bool beginKeyboardInteractiveCallAdmission();
    bool holdKeyboardInteractiveResponseAdmission();
    void abortKeyboardInteractiveCallbackNoWire(int transportFd) noexcept;

    /** 打开 SSH 会话通道 */
    int openChannel();

    /** 请求 PTY (终端类型 + 初始尺寸) */
    int requestPty(int cols, int rows);

    /** Send the optional bounded LANG channel request before PTY/shell startup. */
    int requestSessionLocale(const std::string& locale);

    /** 启动远程 Shell */
    int startShell();

    /** 非阻塞等待并重试 libssh2 操作 (0=读 1=写) */
    bool connectRouteCancelled() const;
    std::chrono::steady_clock::time_point connectRouteDeadline() const noexcept;
    void setConnectRouteDeadline(
        std::chrono::steady_clock::time_point deadline) noexcept;
    bool connectRouteDeadlineExpired() const noexcept;
    std::chrono::steady_clock::time_point boundedConnectStageDeadline(
        std::chrono::milliseconds stageBudget) const noexcept;
    int routeWriteFailure(int deadlineError) const noexcept;
    bool admitRouteWrite(
        const remotedesk::net::NetworkGenerationSnapshot& networkSnapshot,
        const std::function<void()>& write) const;
    bool admitConnectedRouteWrite(const std::function<void()>& write) const;
    /**
     * libssh2 channel reads can synchronously emit SSH window-adjust packets.
     * Keep those apparently inbound calls behind the same route fence as an
     * explicit write so a generation update cannot leave an old-route send.
     */
    bool admitConnectedRouteRead(const std::function<void()>& read) const;
    int waitSocket(int direction, int timeoutSec);
    int waitSocketMilliseconds(int direction, int timeoutMs);

    // ---- 后台 reader 线程 (推送式) ----
    std::thread        readerThread_;
    // Serializes thread object creation/reclamation with stopReader(). The
    // owner flag alone is insufficient while std::thread is being assigned.
    std::mutex          readerLifecycleMutex_;
    std::atomic<bool>  readerRunning_{false};
    std::atomic<bool>  reactorAlive_{false};
    // The reader thread is the per-session libssh2 owner after connect. All
    // terminal, SFTP, PTY and command work is dispatched to this thread; no
    // other worker may call libssh2 directly once the owner is running.
    std::thread::id     reactorThreadId_;
    std::mutex          reactorCommandMutex_;
    std::condition_variable reactorCommandCondition_;
    std::deque<std::function<void()>> reactorCommands_;
    DataCallback       onDataCallback_;
    std::mutex         callbackMutex_;          // 保护 onDataCallback_
    // Serializes callback delivery with detach/reattach replay so bytes read
    // while a tab is hidden cannot overtake the retained FIFO.
    std::mutex         callbackDeliveryMutex_;
    std::mutex         stateCallbackMutex_;     // 保护 stateCallback_
    std::mutex         sshLifecycleCallbackMutex_;
    SshLifecycleStateCallback sshLifecycleStateCallback_;
    mutable std::mutex sessionMutex_;           // 串行化 libssh2 session/channel 操作
    mutable std::recursive_mutex lifecycleMutex_; // 串行化 connect/disconnect 生命周期
    std::atomic<bool> connectCancelRequested_{false};
    SshTerminalDiagnostics diagnostics_;
    std::atomic<bool> transportRecoveryRequested_{false};
    // Transport/KEX/auth are internal steps of Reconnecting. MFA remains
    // visible as NeedsAuthentication because it waits for the page broker.
    std::atomic<bool> recoveryAttemptInProgress_{false};
    std::atomic<uint64_t> lastNetworkGeneration_{0};
    std::atomic<bool> networkAvailable_{true};
    // One route attempt (direct/proxy/jump) owns one process-network snapshot.
    // Reconnect captures a fresh snapshot before resolving again.
    remotedesk::net::NetworkGenerationSnapshot connectNetworkSnapshot_ {};
    // Connection establishment and auxiliary operations share one immutable
    // absolute deadline across DNS, proxy/jump, KEX, auth and channel work.
    // Store clock ticks atomically because the ProxyJump relay also consults
    // the admission boundary while the owner activates or retires a route.
    std::atomic<std::chrono::steady_clock::duration::rep>
        connectRouteDeadlineTicks_ {
            std::chrono::steady_clock::time_point::max()
                .time_since_epoch().count()};

    static constexpr size_t kDetachedTerminalMaxChunks = 512;
    static constexpr size_t kDetachedTerminalMaxBytes = 8 * 1024 * 1024;
    std::mutex detachedTerminalMutex_;
    std::deque<std::vector<uint8_t>> detachedTerminalOutput_;
    size_t detachedTerminalOutputBytes_ = 0;

    /** session owner loop: short poll → input/commands → channel read/callback */
    void readerLoop();
    void drainReactorCommands();
    void drainInputQueueOnReactor();
    /** Read interactive-shell output while an owner command (SFTP/latency) yields. */
    void drainShellOutputOnReactor();
    /** Deliver to the visible consumer or retain bytes for a detached tab. */
    void deliverTerminalOutput(const std::vector<uint8_t>& data);
    void clearDetachedTerminalOutput();
    /** Send an idle-session keepalive without creating a second libssh2 owner. */
    void serviceKeepaliveOnReactor();
    bool isReactorThread() const;

    template <typename Fn>
    auto runOnReactor(Fn&& fn) -> decltype(fn()) {
        using Result = decltype(fn());
        if (isReactorThread()) {
            return fn();
        }
        auto waitForReactorStopped = [this]() {
            if (!reactorAlive_.load(std::memory_order_acquire)) {
                return;
            }
            std::unique_lock<std::mutex> waitLock(reactorCommandMutex_);
            reactorCommandCondition_.wait(waitLock, [this]() {
                return !reactorAlive_.load(std::memory_order_acquire);
            });
        };
        if (!readerRunning_.load(std::memory_order_acquire)) {
            // stopReader() flips readerRunning_ before join(). Wait for the
            // owner to finish before falling back to a direct call, otherwise
            // two threads could enter libssh2 during teardown.
            waitForReactorStopped();
            return fn();
        }
        // 0 = queued, 1 = executing, 2 = cancelled by a reactor stop. The
        // state CAS prevents a caller from running the same operation while
        // the owner is just about to dequeue it.
        auto commandState = std::make_shared<std::atomic<uint8_t>>(0);
        auto task = std::make_shared<std::packaged_task<Result()>>(
            std::forward<Fn>(fn));
        auto future = task->get_future();
        bool stoppedBeforePublish = false;
        bool queueFull = false;
        {
            std::lock_guard<std::mutex> lock(reactorCommandMutex_);
            if (!readerRunning_.load(std::memory_order_acquire)) {
                stoppedBeforePublish = true;
            } else if (reactorCommands_.size() >= kMaxReactorCommands) {
                queueFull = true;
            } else {
                reactorCommands_.emplace_back([task, commandState]() mutable {
                    uint8_t expected = 0;
                    if (!commandState->compare_exchange_strong(
                            expected, static_cast<uint8_t>(1),
                            std::memory_order_acq_rel)) {
                        return;
                    }
                    (*task)();
                });
            }
        }
        if (queueFull) {
            if constexpr (std::is_void_v<Result>) {
                return;
            } else if constexpr (std::is_same_v<Result, int>) {
                return ERR_SSH_REACTOR_QUEUE_FULL;
            } else if constexpr (std::is_same_v<Result, SshForwardingResult>) {
                return SshForwardingResult::Busy;
            } else {
                return Result{};
            }
        }
        if (stoppedBeforePublish) {
            waitForReactorStopped();
            return fn();
        }
        reactorCommandCondition_.notify_one();
        while (future.wait_for(std::chrono::milliseconds(5)) !=
               std::future_status::ready) {
            if (!readerRunning_.load(std::memory_order_acquire)) {
                uint8_t expected = 0;
                if (commandState->compare_exchange_strong(
                        expected, static_cast<uint8_t>(2),
                        std::memory_order_acq_rel)) {
                    // The command may still be queued behind a long-running
                    // owner operation. Do not execute the fallback until the
                    // owner thread has fully stopped.
                    waitForReactorStopped();
                    return fn();
                }
            }
        }
        return future.get();
    }

    /** 启动 / 停止 session owner reactor */
    void startReader();
    void stopReader();
    void processPendingResize();

    template <typename Fn>
    bool postOnReactor(Fn&& fn) {
        if (isReactorThread()) {
            fn();
            return true;
        }
        if (!readerRunning_.load(std::memory_order_acquire)) {
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(reactorCommandMutex_);
            if (!readerRunning_.load(std::memory_order_acquire) ||
                reactorCommands_.size() >= kMaxReactorCommands) {
                return false;
            }
            reactorCommands_.emplace_back(std::forward<Fn>(fn));
        }
        reactorCommandCondition_.notify_one();
        return true;
    }

    struct TerminalInputItem {
        uint64_t sequence = 0;
        uint64_t generation = 0;
        bool control = false;
        bool ordered = false;
        bool orderedEnd = false;
        std::vector<uint8_t> bytes;
    };

    // Terminal input is admitted by any producer but drained only by the
    // session owner reactor. This flag is an admission/lifecycle gate, not a
    // second worker thread.
    std::atomic<bool> terminalInputRunning_{false};
    std::mutex inputQueueMutex_;
    std::condition_variable inputQueueCondition_;
    // Serializes the final admission check with each libssh2 channel write.
    // Teardown takes the same fence before freeing the channel, establishing
    // a linearization point with no post-close write.
    std::mutex inputWriteFenceMutex_;
    std::deque<TerminalInputItem> inputQueue_;
    size_t inputQueueBytes_ = 0;
    size_t inputQueueControlItems_ = 0;
    size_t inputQueueControlBytes_ = 0;
    size_t inputQueueDataItems_ = 0;
    size_t inputQueueDataBytes_ = 0;
    static constexpr size_t kInputQueueMaxItems = SshTerminalInputQueuePolicy::kMaxItems;
    static constexpr size_t kInputQueueMaxBytes = SshTerminalInputQueuePolicy::kMaxBytes;
    static constexpr size_t kInputQueueMaxControlItems =
        SshTerminalInputQueuePolicy::kMaxControlItems;
    static constexpr size_t kInputQueueMaxControlBytes =
        SshTerminalInputQueuePolicy::kMaxControlBytes;
    static constexpr size_t kInputQueueMaxDataItems =
        SshTerminalInputQueuePolicy::kMaxDataItems;
    static constexpr size_t kInputQueueMaxDataBytes =
        SshTerminalInputQueuePolicy::kMaxDataBytes;

    void startTerminalInput();
    void stopTerminalInput();
    void clearInputQueueLocked(bool recordLoss);
    int writeTerminalData(const uint8_t* data, size_t len, uint64_t sequence,
                          bool fromTerminalInput = false);
    std::atomic<bool> terminalInputAccepting_{false};
    // Set only by the session owner reactor while a paste transaction is
    // being drained; atomic teardown makes clearing the queue race-safe.
    std::atomic<bool> orderedInputActive_{false};

    static constexpr size_t kMaxReactorCommands = 256;
    static constexpr int kReactorWaitSliceMs = 5;
    static constexpr size_t kForwardBufferLimit = 512 * 1024;
    static constexpr size_t kForwardAcceptBatch = 8;
    static constexpr size_t kMaxForwardTargetConnectWorkers = 8;
    std::chrono::steady_clock::time_point keepaliveNextDue_ =
        std::chrono::steady_clock::time_point::max();
    uint32_t keepaliveConsecutiveFailures_ = 0;
    std::mutex resizeMutex_;
    bool resizePending_ = false;
    bool resizeCommandPosted_ = false;
    int pendingResizeCols_ = 0;
    int pendingResizeRows_ = 0;

    /** 确保 SFTP 子系统已初始化。调用方必须持有 sessionMutex_。 */
    int ensureSftpLocked(std::unique_lock<std::mutex>& sessionLock);
    /** Cooperative wait/yield for an SFTP slice while retaining handle ownership. */
    bool yieldSftpSlice(std::unique_lock<std::mutex>& sessionLock,
                        int direction, int timeoutSec);
    /** Close a remote SFTP handle without emitting on a retired route. */
    int closeSftpHandleLocked(
        LIBSSH2_SFTP_HANDLE* handle,
        std::unique_lock<std::mutex>& sessionLock,
        bool directory = false);

    // Keep each SFTP ownership slice below the terminal input latency budget.
    // The session mutex is released between slices; the outer SFTP mutex keeps
    // the libssh2 SFTP handle alive while the terminal writer/reader run.
    static constexpr size_t kSftpSliceBytes = 32 * 1024;

    int executeChannelRequest(
        const std::string& request, bool subsystem,
        SshCommandResult& result, int timeoutMs,
        const remotedesk::net::NetworkGenerationSnapshot*
            requiredNetworkSnapshot = nullptr);
};

/** 注册到 ExtensionSystem */
void registerSshAdapter();

#endif // SSH_ADAPTER_H

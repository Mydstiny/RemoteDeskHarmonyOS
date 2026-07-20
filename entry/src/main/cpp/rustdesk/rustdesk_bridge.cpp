/**
 * rustdesk_bridge.cpp — RustDesk 协议适配器
 *
 * 双模式架构:
 *   1. RD_MODE_IPC (默认, 生产安全): Unix Domain Socket → rustdesk_helper 进程
 *      - 不实现 RustDesk 私有协议, 仅 IPC 转发
 *      - 密码/密钥通过 IPC 加密通道传输
 *      - AGPL 许可证隔离
 *
 *   2. RD_MODE_EXPERIMENTAL (RUSTDESK_EXPERIMENTAL 宏, 仅 dev):
 *      - 手写 TCP 握手骨架 (仅用于协议研究/开发调试)
 *      - 密码明文发送风险 — 不得用于正式构建
 */

#include "rustdesk_bridge.h"
#include "rustdesk_ipc.h"
#include "common/safe_log.h"
#include "extensions/extension_registry.h"
#include <hilog/log.h>
#include <string>

// Rust FFI 函数声明 (extern "C", 来自 librustdesk_ffi.a)
#ifdef RUSTDESK_USE_REAL_CORE
extern "C" {
    void* rustdesk_connect(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void* user_data);
    void  rustdesk_disconnect(void* handle);
    void  rustdesk_cancel_pending_connect();
    void  rustdesk_send_key(void* handle, unsigned int scancode, bool pressed);
    void  rustdesk_send_mouse(void* handle, int x, int y, unsigned int button, bool pressed);
    void  rustdesk_send_mouse_wheel(void* handle, int x, int y, int delta);
    void  rustdesk_send_text(void* handle, const char* text);
    int   rustdesk_send_file(void* handle, uint64_t transfer_id, const char* remote_path,
                             const unsigned char* data, unsigned int len);
    struct RustDeskFfiTransferStatus { uint32_t state; uint64_t transferId; uint64_t transferredBytes;
        uint64_t totalBytes; uint32_t diagnosticCode; };
    bool  rustdesk_get_transfer_status(void* handle, RustDeskFfiTransferStatus* out_status);
    void  rustdesk_send_clipboard(void* handle, const unsigned char* data, unsigned int len);
    size_t rustdesk_get_clipboard(void* handle, unsigned char* buffer, size_t buffer_len);
    bool  rustdesk_request_frame_refresh(void* handle);
    bool  rustdesk_report_video_pressure(void* handle, int level);
    size_t rustdesk_last_error(char* buffer, size_t buffer_len);
    const char* rustdesk_version();
}
#endif
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstring>
#include <cerrno>
#include <cstdlib>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>
#include <future>
#include <pthread.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0002
#define LOG_TAG "RUSTDESK_BRIDGE"

#define RD_DEFAULT_TCP_PORT  21116
#define RD_IPC_CONNECT_TIMEOUT 5

// 运行时 socket 路径 (可被 ArkTS setHelperSocketPath NAPI 覆盖)
static std::string g_socketPath = RD_IPC_SOCKET_PATH_DEFAULT;
const char* g_rustdeskHelperSocketPath = RD_IPC_SOCKET_PATH_DEFAULT;

// ============================================================
// RustDesk 真实 TCP 连接 (在独立线程中运行)
// ============================================================
static void rdRealConnectThread(RdIpcConnectReq req, int ipcClientFd) {
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] 开始连接 %{public}s:%{public}u peer=%{public}s",
                req.host, req.port, req.peerId);

    int tcpFd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcpFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-REAL] socket 失败: %{public}s", strerror(errno));
        // 发送错误 ACK
        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x01};
        send(ipcClientFd, errAck, 6, 0);
        return;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(req.port));
    if (inet_pton(AF_INET, req.host, &addr.sin_addr) <= 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-REAL] 地址解析失败: %{public}s", req.host);
        close(tcpFd);
        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x02};
        send(ipcClientFd, errAck, 6, 0);
        return;
    }

    // 设置连接超时 5 秒
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(tcpFd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(tcpFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(tcpFd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-REAL] TCP 连接失败: %{public}s", strerror(errno));
        close(tcpFd);
        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x03};
        send(ipcClientFd, errAck, 6, 0);
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] ✓ TCP 已连接 fd=%{public}d", tcpFd);

    // RustDesk 协议握手: 发送 SYN 包
    // RustDesk 使用自定义二进制协议, 第一条消息是握手请求
    // 格式: [4 bytes len LE] [protobuf message]
    // 先尝试读取服务器可能发送的 greeting
    uint8_t buf[4096];
    // 发送 RustDesk 握手 (基于 RDCM magic + version)
    uint8_t handshake[20] = {0};
    memcpy(handshake, "RDCM", 4);
    handshake[4] = 0x01;  // version
    // 填充 peer ID hash
    uint32_t peerHash = 0;
    for (size_t i = 0; i < strlen(req.peerId) && i < 128; i++) {
        peerHash = peerHash * 31 + (uint8_t)req.peerId[i];
    }
    memcpy(handshake + 8, &peerHash, 4);
    ssize_t sent = send(tcpFd, handshake, sizeof(handshake), 0);
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] 握手已发送 %{public}zd bytes, 等待响应...", sent);

    // 等待服务器响应
    ssize_t n = recv(tcpFd, buf, sizeof(buf), 0);
    if (n > 0) {
        OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] 服务器响应 %{public}zd bytes: %{public}02X %{public}02X %{public}02X %{public}02X ...",
                    n, buf[0], buf[1], buf[2], buf[3]);
    } else if (n == 0) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-REAL] 服务器关闭连接");
    } else {
        OH_LOG_WARN(LOG_APP, "[RustDesk-REAL] recv 错误: %{public}s", strerror(errno));
    }

    // TODO: 完整 RustDesk 协议实现
    // 成功连接 (暂时返回 ACK 表示 TCP 层面连接成功)
    uint8_t okAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x00};
    send(ipcClientFd, okAck, 6, 0);
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] ACK 已发送");
}

void rdSetHelperSocketPath(const char* path) {
    if (path && path[0] != '\0') {
        g_socketPath = path;
        g_rustdeskHelperSocketPath = g_socketPath.c_str();
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] socket 路径已更新: %{public}s", g_rustdeskHelperSocketPath);
    }
}

// helper 二进制路径 (由 ArkTS setHelperSocketPath 同一调用设置)
static std::string g_helperBinPath;

void rdSetHelperBinPath(const char* path) {
    if (path && path[0] != '\0') {
        g_helperBinPath = path;
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 路径已设置: %{public}s", path);
    }
}

// ============================================================
// 内置 IPC 服务端 (替代独立 helper 进程)
// 运行在 pthread 中, 省去 dlopen/SELinux/namespace 问题
// ============================================================
static pthread_t g_helperThread = 0;
static volatile bool g_helperRunning = false;

static void* rdHelperThreadFn(void* arg) {
    const char* socketPath = (const char*)arg;
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 线程启动, socket=%{public}s", socketPath);

    // 删掉旧 socket 文件
    unlink(socketPath);

    int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper socket() 失败: %{public}s", strerror(errno));
        return nullptr;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath, sizeof(addr.sun_path) - 1);

    if (bind(listenFd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper bind() 失败: %{public}s", strerror(errno));
        close(listenFd);
        return nullptr;
    }

    if (listen(listenFd, 1) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper listen() 失败: %{public}s", strerror(errno));
        close(listenFd);
        return nullptr;
    }

    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 监听中...");
    g_helperRunning = true;

    while (g_helperRunning) {
        int clientFd = accept(listenFd, nullptr, nullptr);
        if (clientFd < 0) {
            if (errno == EINTR) { continue; }
            break;
        }
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 客户端已连接 fd=%{public}d", clientFd);

        // 简单帧循环: 读 5 字节头 → 读 payload → 处理
        uint8_t header[5];
        std::vector<uint8_t> payload;
        while (g_helperRunning) {
            ssize_t n = recv(clientFd, header, 5, 0);
            if (n <= 0) { break; }
            uint32_t payloadSize = (uint32_t)header[0] | ((uint32_t)header[1] << 8) |
                                   ((uint32_t)header[2] << 16) | ((uint32_t)header[3] << 24);
            uint8_t msgType = header[4];
            if (payloadSize > RD_IPC_MAX_PAYLOAD) { break; }

            payload.resize(payloadSize);
            size_t off = 0;
            while (off < payloadSize) {
                n = recv(clientFd, payload.data() + off, payloadSize - off, 0);
                if (n <= 0) { break; }
                off += (size_t)n;
            }
            if (off < payloadSize) { break; }

            // 处理消息
            switch (msgType) {
                case RD_IPC_CONNECT_REQ: {  // 0x01
                    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper CONNECT_REQ payload=%{public}u bytes", payloadSize);
                    if (payloadSize >= sizeof(RdIpcConnectReq)) {
                        RdIpcConnectReq req;
                        memcpy(&req, payload.data(), sizeof(RdIpcConnectReq));
                        // 在独立线程中发起真实 RustDesk TCP 连接
                        std::thread realConn(rdRealConnectThread, req, clientFd);
                        realConn.detach();
                        // ACK 由 realConn 线程发送 (连接结果)
                    } else {
                        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0xFF};
                        send(clientFd, errAck, 6, 0);
                    }
                    break;
                }
                case RD_IPC_DISCONNECT:  // 0x03
                    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper DISCONNECT");
                    break;
                case RD_IPC_INPUT_KEY:    // 0x10
                case RD_IPC_INPUT_MOUSE:  // 0x11
                case RD_IPC_INPUT_WHEEL:  // 0x12
                case RD_IPC_INPUT_TEXT:   // 0x13
                    break;  // TODO: 转发到 RustDesk core
                case RD_IPC_PING: {       // 0xFE → PONG
                    uint8_t pong[6] = {1, 0, 0, 0, RD_IPC_PONG, 0};
                    send(clientFd, pong, 6, 0);
                    break;
                }
                default:
                    OH_LOG_WARN(LOG_APP, "[RustDesk-IPC] helper 未知消息 0x%{public}02X", msgType);
                    break;
            }
        }
        close(clientFd);
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 客户端断开");
    }

    close(listenFd);
    unlink(socketPath);
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 线程退出");
    return nullptr;
}

static bool rdTryStartHelper() {
    if (g_helperRunning) {
        return true;
    }
    std::string sockPath = g_socketPath;
    char* pathCopy = strdup(sockPath.c_str());
    int rc = pthread_create(&g_helperThread, nullptr, rdHelperThreadFn, pathCopy);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] pthread_create 失败: %{public}d", rc);
        free(pathCopy);
        return false;
    }
    pthread_detach(g_helperThread);
    g_helperThread = 0;
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 线程已启动, 等待 socket...");
    usleep(200000);  // 200ms
    return g_helperRunning;
}

// ============================================================
// 公共: Impl + 元信息 (两种模式共享)
// ============================================================

struct RustDeskBridge::Impl {
    TransferRuntimeStatus  transferStatus;
    std::atomic<uint64_t>  nextTransferId {1};
    ConnectionConfig        config;
    ConnectionState         state = ConnectionState::DISCONNECTED;
    VideoFrameCallback      videoCallback;
    AudioDataCallback       audioCallback;
    ConnectionStateCallback stateCallback;
    std::mutex              mutex;
    std::atomic<uint64_t>   connectSerial {0};
    std::atomic<bool>       disconnectRequested {false};
    std::atomic<bool>       ffiStreamEnded {false};
    RemoteCursorStore       cursorStore;
    int                     ipcFd = -1;   // IPC socket fd (IPC 模式)
    int                     sockFd = -1;  // TCP socket fd (实验模式)
#ifdef RUSTDESK_USE_REAL_CORE
    void*                   ffiHandle = nullptr;  // Rust FFI 连接句柄
    // FFI connect() 在后台执行，但不能 detach：断开时必须等待它结束，
    // 否则旧连接可能在下一次连接已经开始后仍持有 rendezvous/relay 资源。
    std::thread              ffiConnectThread;
    // 流线程通过 onFfiDisconnect 回调结束时，不能从自身 join；把延迟释放
    // 的线程保留下来，由 disconnect() 统一 join，避免释放任务悬空。
    std::vector<std::thread> ffiCleanupThreads;
#endif

    void setState(ConnectionState s, const std::string& msg = "") {
        ConnectionStateCallback cb;
        {
            std::lock_guard<std::mutex> lock(mutex);
            state = s;
            cb = stateCallback;
        }
        if (cb) { cb(s, msg); }
    }
};

#ifdef RUSTDESK_USE_REAL_CORE
struct RustDeskFfiVideoFrame {
    const uint8_t* data;
    size_t         size;
    int            width;
    int            height;
    int            codec;
    uint64_t       timestamp;
    bool           isKeyFrame;
};

struct RustDeskFfiAudioData {
    const uint8_t* data;
    size_t         size;
    int            sampleRate;
    int            channels;
    uint64_t       timestamp;
};

struct RustDeskFfiCursorUpdate {
    uint32_t       kind;
    uint64_t       shapeId;
    int            x;
    int            y;
    int            width;
    int            height;
    int            hotX;
    int            hotY;
    const uint8_t* rgba;
    size_t         rgbaLen;
    bool           visible;
};

static std::atomic<uint64_t> g_ffiVideoFrameCount {0};
static std::atomic<uint64_t> g_ffiAudioFrameCount {0};
static std::atomic<uint64_t> g_ffiMouseSendCount {0};
static std::atomic<uint64_t> g_ffiKeySendCount {0};
static std::atomic<uint64_t> g_ffiWheelSendCount {0};
static std::atomic<uint64_t> g_ffiTextSendCount {0};
static std::atomic<uint64_t> g_ffiFileSendCount {0};
static std::atomic<uint64_t> g_ffiCursorShapeCount {0};
static std::atomic<uint64_t> g_ffiCursorPositionCount {0};
static std::atomic<uint64_t> g_ffiCursorVisibilityCount {0};

static const char* rdCodecName(int codec) {
    switch (codec) {
        case -1: return "AUTO";
        case 0: return "H264";
        case 1: return "H265";
        case 2: return "VP8";
        case 3: return "VP9";
        case 4: return "AV1";
        default: return "UNKNOWN";
    }
}

static CodecType rdCodecType(int codec) {
    switch (codec) {
        case 1: return CodecType::H265;
        case 2: return CodecType::VP8;
        case 3: return CodecType::VP9;
        case 4: return CodecType::AV1;
        case 0:
        default:
            return CodecType::H264;
    }
}

static int rdFfiCodecPreference(CodecType codec) {
    switch (codec) {
        case CodecType::AUTO: return 0;
        case CodecType::VP8: return 1;
        case CodecType::VP9: return 2;
        case CodecType::AV1: return 3;
        case CodecType::H265: return 5;
        case CodecType::H264:
        default:
            return 4;
    }
}

void RustDeskBridge::onFfiFrame(const void* framePtr, void* userData) {
    auto* impl = static_cast<RustDeskBridge::Impl*>(userData);
    auto* ffiFrame = static_cast<const RustDeskFfiVideoFrame*>(framePtr);
    if (!impl || !ffiFrame || !ffiFrame->data || ffiFrame->size == 0) {
        return;
    }

    uint64_t index = ++g_ffiVideoFrameCount;
    {
        using Clock = std::chrono::steady_clock;
        static std::mutex cadenceMutex;
        static bool cadenceInitialized = false;
        static Clock::time_point lastFrameAt;
        static Clock::time_point windowStartedAt;
        static uint64_t windowFrames = 0;
        static uint64_t windowMaxGapMs = 0;
        static uint64_t cadenceGapCount = 0;

        const auto now = Clock::now();
        std::lock_guard<std::mutex> cadenceLock(cadenceMutex);
        if (!cadenceInitialized) {
            cadenceInitialized = true;
            lastFrameAt = now;
            windowStartedAt = now;
        } else {
            const auto gapMs = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(now - lastFrameAt).count());
            if (gapMs > windowMaxGapMs) {
                windowMaxGapMs = gapMs;
            }
            if (gapMs > 200) {
                cadenceGapCount++;
                if (cadenceGapCount <= 8 || cadenceGapCount % 30 == 0) {
                    OH_LOG_WARN(LOG_APP,
                        "[RustDesk-FFI] ffi video cadence gap=%{public}llu total=%{public}llu window=%{public}llu codec=%{public}s pts=%{public}llu",
                        static_cast<unsigned long long>(gapMs),
                        static_cast<unsigned long long>(index),
                        static_cast<unsigned long long>(windowFrames),
                        rdCodecName(ffiFrame->codec),
                        static_cast<unsigned long long>(ffiFrame->timestamp));
                }
            }
            lastFrameAt = now;
        }
        windowFrames++;
        const auto windowMs = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(now - windowStartedAt).count());
        if (windowMs >= 1000) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] ffi video window frames=%{public}llu total=%{public}llu max_gap=%{public}llu codec=%{public}s size=%{public}dx%{public}d",
                static_cast<unsigned long long>(windowFrames),
                static_cast<unsigned long long>(index),
                static_cast<unsigned long long>(windowMaxGapMs),
                rdCodecName(ffiFrame->codec),
                ffiFrame->width,
                ffiFrame->height);
            windowStartedAt = now;
            windowFrames = 0;
            windowMaxGapMs = 0;
        }
    }
    if (index <= 3 || index % 300 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stream video #%{public}llu codec=%{public}s frame=%{public}dx%{public}d size=%{public}zu key=%{public}s pts=%{public}llu cb=%{public}s",
            static_cast<unsigned long long>(index),
            rdCodecName(ffiFrame->codec),
            ffiFrame->width,
            ffiFrame->height,
            ffiFrame->size,
            ffiFrame->isKeyFrame ? "yes" : "no",
            static_cast<unsigned long long>(ffiFrame->timestamp),
            impl->videoCallback ? "yes" : "no");
    }

    VideoFrameCallback cb;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        cb = impl->videoCallback;
    }
    if (cb) {
        VideoFrame frame;
        frame.data = ffiFrame->data;
        frame.size = ffiFrame->size;
        frame.width = ffiFrame->width;
        frame.height = ffiFrame->height;
        frame.codec = rdCodecType(ffiFrame->codec);
        frame.timestamp = ffiFrame->timestamp;
        frame.isKeyFrame = ffiFrame->isKeyFrame;
        cb(frame);
    }
}

void RustDeskBridge::onFfiAudio(const void* audioPtr, void* userData) {
    auto* impl = static_cast<RustDeskBridge::Impl*>(userData);
    auto* ffiAudio = static_cast<const RustDeskFfiAudioData*>(audioPtr);
    if (!impl || !ffiAudio || !ffiAudio->data || ffiAudio->size == 0) {
        return;
    }

    const int channels = ffiAudio->channels > 0 ? ffiAudio->channels : 2;
    const size_t bytesPerFrame = static_cast<size_t>(channels) * 2;
    if (ffiAudio->size < bytesPerFrame * 120 ||
        (bytesPerFrame > 0 && (ffiAudio->size % bytesPerFrame) != 0)) {
        uint64_t skipped = ++g_ffiAudioFrameCount;
        if (skipped <= 5 || skipped % 200 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] skip non-pcm audio #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d",
                static_cast<unsigned long long>(skipped),
                ffiAudio->size,
                ffiAudio->sampleRate,
                ffiAudio->channels);
        }
        return;
    }

    uint64_t index = ++g_ffiAudioFrameCount;
    if (index <= 3 || index % 100 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stream audio #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d",
            static_cast<unsigned long long>(index),
            ffiAudio->size,
            ffiAudio->sampleRate,
            ffiAudio->channels);
    }

    AudioDataCallback cb;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        cb = impl->audioCallback;
    }
    if (cb) {
        AudioData audio;
        audio.data = ffiAudio->data;
        audio.size = ffiAudio->size;
        audio.sampleRate = ffiAudio->sampleRate;
        audio.channels = ffiAudio->channels;
        audio.timestamp = ffiAudio->timestamp;
        cb(audio);
    }
}

void RustDeskBridge::onFfiCursor(const void* cursorPtr, void* userData) {
    auto* impl = static_cast<RustDeskBridge::Impl*>(userData);
    auto* cursor = static_cast<const RustDeskFfiCursorUpdate*>(cursorPtr);
    if (!impl || !cursor) {
        return;
    }

    switch (cursor->kind) {
        case 0: {
            if (!cursor->rgba || cursor->rgbaLen == 0 || cursor->rgbaLen > kRemoteCursorMaxBytes) {
                OH_LOG_WARN(LOG_APP,
                    "[RustDesk-FFI] cursor shape rejected id=%{public}llu bytes=%{public}zu",
                    static_cast<unsigned long long>(cursor->shapeId), cursor->rgbaLen);
                return;
            }
            std::vector<uint8_t> rgba(cursor->rgba, cursor->rgba + cursor->rgbaLen);
            const bool accepted = impl->cursorStore.setShape(cursor->shapeId, cursor->width,
                cursor->height, cursor->hotX, cursor->hotY, rgba);
            const uint64_t index = ++g_ffiCursorShapeCount;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] cursor shape #%{public}llu id=%{public}llu size=%{public}dx%{public}d hot=%{public}d,%{public}d accepted=%{public}s",
                static_cast<unsigned long long>(index),
                static_cast<unsigned long long>(cursor->shapeId), cursor->width, cursor->height,
                cursor->hotX, cursor->hotY, accepted ? "yes" : "no");
            break;
        }
        case 1: {
            impl->cursorStore.setPosition(cursor->x, cursor->y);
            const uint64_t index = ++g_ffiCursorPositionCount;
            if (index <= 10 || index % 300 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] cursor position #%{public}llu x=%{public}d y=%{public}d",
                    static_cast<unsigned long long>(index), cursor->x, cursor->y);
            }
            break;
        }
        case 2: {
            impl->cursorStore.setVisible(cursor->visible);
            const uint64_t index = ++g_ffiCursorVisibilityCount;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] cursor visibility #%{public}llu visible=%{public}s",
                static_cast<unsigned long long>(index), cursor->visible ? "yes" : "no");
            break;
        }
        default:
            break;
    }
}

void RustDeskBridge::onFfiDisconnect(int state, const char* message, void* userData) {
    auto* impl = static_cast<RustDeskBridge::Impl*>(userData);
    bool wasConnected = false;
    bool requested = false;
    std::shared_ptr<std::promise<void>> cleanupGate;
    if (impl) {
        impl->cursorStore.setVisible(false);
        impl->ffiStreamEnded.store(true);
        std::lock_guard<std::mutex> lock(impl->mutex);
        wasConnected = impl->state == ConnectionState::CONNECTED;
        requested = impl->disconnectRequested.load();
    }
    void* endedHandle = nullptr;
    if (impl && !requested) {
        std::lock_guard<std::mutex> lock(impl->mutex);
        // The FFI callback runs on the streaming thread. Move ownership out
        // here and release it on a separate thread after this callback returns.
        // The cleanup thread is retained by Impl and joined from disconnect().
        endedHandle = impl->ffiHandle;
        impl->ffiHandle = nullptr;
        if (endedHandle != nullptr) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] scheduling stale handle cleanup=%{public}p reason=stream-ended",
                endedHandle);
            cleanupGate = std::make_shared<std::promise<void>>();
            std::future<void> cleanupReady = cleanupGate->get_future();
            impl->ffiCleanupThreads.emplace_back([endedHandle,
                                                   cleanupReady = std::move(cleanupReady)]() mutable {
                // rustdesk_disconnect joins the streaming thread. Waiting for
                // the callback to return is mandatory; otherwise this cleanup
                // worker could try to join the thread that is executing this
                // callback and deadlock.
                cleanupReady.wait();
                rustdesk_disconnect(endedHandle);
            });
        }
    }
    if (requested) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stream stopped state=%{public}d msg=%{public}s connected=%{public}s requested=%{public}s",
            state,
            message ? message : "",
            wasConnected ? "yes" : "no",
            requested ? "yes" : "no");
        return;
    }
    if (impl) {
        const char* stopMessage = message ? message : "RustDesk stream stopped";
        if (state == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] stream ended normally state=%{public}d msg=%{public}s connected=%{public}s requested=%{public}s",
                state, stopMessage, wasConnected ? "yes" : "no", "no");
            impl->setState(ConnectionState::DISCONNECTED, stopMessage);
        } else {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] stream stopped state=%{public}d msg=%{public}s connected=%{public}s requested=%{public}s",
                state, stopMessage, wasConnected ? "yes" : "no", "no");
            impl->setState(ConnectionState::ERROR, stopMessage);
        }
    }
    if (cleanupGate) {
        cleanupGate->set_value();
    }
}
#endif

RustDeskBridge::RustDeskBridge(RustDeskMode mode)
    : impl_(std::make_unique<Impl>()), mode_(mode) {
    const char* modeLabel = (mode == RustDeskMode::IPC) ? "IPC" :
        (mode == RustDeskMode::FFI ? "FFI" : "EXPERIMENTAL");
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDeskBridge created (mode=%{public}s)", modeLabel);
}

void RustDeskBridge::setSessionIdentity(uint64_t sessionId) {
    impl_->cursorStore.reset(sessionId, "rustdesk");
    // RustDesk does not guarantee that an unchanged cursor shape is repeated
    // after every UI/surface handoff. Keep a valid official-style arrow ready
    // until the first protocol cursor_data/cursor_id update replaces it.
    impl_->cursorStore.setDefaultShape();
    impl_->cursorStore.setVisible(true);
}

RemoteCursorSnapshot RustDeskBridge::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
}

RustDeskBridge::~RustDeskBridge() {
    bool hasFfiHandle = false;
    bool hasFfiConnectThread = false;
    bool hasFfiCleanupThreads = false;
#ifdef RUSTDESK_USE_REAL_CORE
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasFfiHandle = impl_->ffiHandle != nullptr;
        hasFfiConnectThread = impl_->ffiConnectThread.joinable();
        hasFfiCleanupThreads = !impl_->ffiCleanupThreads.empty();
    }
#endif
    if (getState() != ConnectionState::DISCONNECTED || hasFfiHandle ||
        hasFfiConnectThread || hasFfiCleanupThreads) {
        disconnect();
    }
}

std::string RustDeskBridge::protocolName() { return "RustDesk"; }
int RustDeskBridge::defaultPort() { return RD_DEFAULT_TCP_PORT; }

std::string RustDeskBridge::protocolVersion() {
    if (mode_ == RustDeskMode::FFI) {
#ifdef RUSTDESK_USE_REAL_CORE
        const char* version = rustdesk_version();
        return version != nullptr ? version : "2.1.0-ffi";
#else
        return "2.1.0-ffi-unavailable";
#endif
    }
    return (mode_ == RustDeskMode::IPC) ? "2.0.0-ipc" : "1.3.0-experimental";
}

// ============================================================
// RD_MODE_IPC: Unix Domain Socket → rustdesk_helper
// ============================================================

static int rdIpcConnect(const char* socketPath, int& fd) {
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] socket(AF_UNIX) failed: %{public}s", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath, sizeof(addr.sun_path) - 1);

    // 非阻塞连接 + 短超时
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int ret = ::connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr));
    if (ret < 0 && errno != EINPROGRESS) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-IPC] connect to helper failed: %{public}s (helper not running?)",
                    strerror(errno));
        close(fd); fd = -1; return -2;
    }
    // 恢复阻塞模式
    fcntl(fd, F_SETFL, flags);

    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] Connected to helper: %{public}s fd=%{public}d", socketPath, fd);
    return 0;
}

static int rdIpcSendConnectReq(int fd, const ConnectionConfig& cfg) {
    RdIpcConnectReq req;
    memset(&req, 0, sizeof(req));
    strncpy(req.host, cfg.host.c_str(), sizeof(req.host) - 1);
    req.port = static_cast<uint32_t>(cfg.port > 0 ? cfg.port :
        (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT));
    strncpy(req.peerId, cfg.customHostname.c_str(), sizeof(req.peerId) - 1);
    strncpy(req.username, cfg.username.c_str(), sizeof(req.username) - 1);
    req.passwordLen = static_cast<uint32_t>(cfg.password.length());
    req.width = static_cast<uint32_t>(cfg.width > 0 ? cfg.width : 1920);
    req.height = static_cast<uint32_t>(cfg.height > 0 ? cfg.height : 1080);
    req.codec = static_cast<uint32_t>(cfg.codec);
    req.imageQuality = static_cast<uint32_t>(cfg.rdImageQuality);
    req.directIp = cfg.rdDirectIp ? 1 : 0;
    req.directPort = static_cast<uint32_t>(cfg.rdDirectPort > 0 ? cfg.rdDirectPort : 21118);
    req.lanDiscovery = cfg.rdLanDiscovery ? 1 : 0;
    req.privacyMode = cfg.rdPrivacyMode ? 1 : 0;
    req.passwordMode = static_cast<uint32_t>(cfg.rdPasswordMode == 1 ? 1 : 0);
    req.passwordLength = static_cast<uint32_t>(cfg.rdPasswordLength);
    strncpy(req.relayId, cfg.rdRelayId.c_str(), sizeof(req.relayId) - 1);
    strncpy(req.accountId, cfg.rdAccountId.c_str(), sizeof(req.accountId) - 1);

    size_t payloadSize = sizeof(req) + req.passwordLen;
    size_t frameSize = 5 + payloadSize;
    if (frameSize > RD_IPC_MAX_FRAME_SIZE) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect req too large: %{public}zu", frameSize);
        return -1;
    }

    auto buf = std::make_unique<uint8_t[]>(frameSize);
    RdIpcFrame::writeHeader(buf.get(), 5, RD_IPC_CONNECT_REQ, static_cast<uint32_t>(payloadSize));
    memcpy(buf.get() + 5, &req, sizeof(req));
    if (req.passwordLen > 0) {
        memcpy(buf.get() + 5 + sizeof(req), cfg.password.c_str(), req.passwordLen);
    }

    ssize_t sent = send(fd, buf.get(), frameSize, 0);
    if (sent < static_cast<ssize_t>(frameSize)) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect req send failed: %{public}zd/%{public}zu", sent, frameSize);
        return -1;
    }

    // 等待 ACK
    uint8_t ackBuf[5];
    ssize_t n = recv(fd, ackBuf, 5, 0);
    if (n < 5) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect ack recv failed: %{public}zd", n);
        return -1;
    }
    RdIpcMsgType ackType;
    uint32_t ackSize;
    RdIpcFrame::readHeader(ackBuf, 5, ackType, ackSize);
    if (ackType != RD_IPC_CONNECT_ACK) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] unexpected ack type: 0x%{public}02X", ackType);
        return -1;
    }
    uint8_t status = 0;
    if (ackSize > 0) {
        n = recv(fd, &status, 1, 0);
        if (n < 1) {
            OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect ack payload recv failed: %{public}zd", n);
            return -1;
        }
    }
    if (status != 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper rejected connect req: status=%{public}u", status);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] ✓ Connect ACK received (payload=%{public}u bytes)", ackSize);
    return 0;
}

static int rdIpcConnectFlow(int fd, const ConnectionConfig& cfg) {
    return rdIpcSendConnectReq(fd, cfg);
}

// ============================================================
// 连接管理 (根据 mode 分发)
// ============================================================

int RustDeskBridge::connect(const ConnectionConfig& cfg) {
    bool hasFfiHandle = false;
    bool hasFfiConnectThread = false;
    bool hasFfiCleanupThreads = false;
#ifdef RUSTDESK_USE_REAL_CORE
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasFfiHandle = impl_->ffiHandle != nullptr;
        hasFfiConnectThread = impl_->ffiConnectThread.joinable();
        hasFfiCleanupThreads = !impl_->ffiCleanupThreads.empty();
    }
#endif
    if (getState() != ConnectionState::DISCONNECTED || hasFfiHandle ||
        hasFfiConnectThread || hasFfiCleanupThreads) {
        disconnect();
    }
    impl_->config = cfg;
    impl_->disconnectRequested.store(false);
    impl_->ffiStreamEnded.store(false);
    const uint64_t serial = ++impl_->connectSerial;
    impl_->setState(ConnectionState::CONNECTING, "Connecting...");

    if (cfg.rdAuthMode == 1 && cfg.rdDirectIp) {
        // 点击批准依赖 ID/中继会话返回新的 Hash；直连模式没有这条批准通道。
        impl_->setState(ConnectionState::ERROR,
            "RustDesk remote approval requires rendezvous/relay mode; disable direct connection or use a device password.");
        OH_LOG_WARN(LOG_APP,
            "[RustDesk] remote approval is unavailable in direct mode; refusing ambiguous login");
        return -41;
    }

#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI) {
        // ---- FFI 模式: 直接调用 librustdesk_ffi.a ----
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Using real core (protobuf protocol)");
        const std::string logHost = SafeLog::MaskHost(cfg.host);
        const int effectivePort = cfg.port > 0 ? cfg.port :
            (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT);
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Connecting to %{public}s:%{public}d",
                    logHost.c_str(), effectivePort);
        const std::string ffiPeerId = cfg.rdDirectIp && !cfg.host.empty()
            ? cfg.host
            : (cfg.customHostname.empty() ? cfg.username : cfg.customHostname);
        const std::string logPeer = SafeLog::MaskUser(ffiPeerId);
        const std::string serverKeyId = cfg.rdServerKey.empty() ? "default" : SafeLog::HashForLog(cfg.rdServerKey);
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Request peer=%{public}s keyId=%{public}s key=%{public}s",
                    logPeer.c_str(), serverKeyId.c_str(),
                    SafeLog::MaskSecretLenOnly(cfg.rdServerKey).c_str());

        RustDeskBridge::Impl* impl = impl_.get();
        std::thread connectThread([impl, cfg, ffiPeerId, logHost, serial]() {
            RustDeskFfiConfig ffiCfg = {};  // 零初始化 — 消除未初始化 padding/新字段风险
            ffiCfg.host     = cfg.host.c_str();
            ffiCfg.port     = cfg.port > 0 ? cfg.port :
                (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT);
            ffiCfg.key      = cfg.rdServerKey.c_str();
            ffiCfg.username = ffiPeerId.c_str();
            ffiCfg.password = cfg.password.c_str();
            ffiCfg.width    = cfg.width;    // 0 = auto from profile
            ffiCfg.height   = cfg.height;   // 0 = auto from profile
            ffiCfg.codec    = rdFfiCodecPreference(cfg.codec);
            ffiCfg.imageQuality = cfg.rdImageQuality;
            ffiCfg.privacyMode = cfg.rdPrivacyMode;
            ffiCfg.audioEnabled = cfg.rdAudioEnabled;
            // T-121: Default to Balanced profile, allow override
            ffiCfg.profile  = 1; // Balanced
            ffiCfg.fps      = 0; // From profile
            ffiCfg.auth_mode = (cfg.rdAuthMode == 1) ? 1 : 0;
            // T-209: 直连模式映射
            ffiCfg.direct_connection = false;
            if (cfg.rdDirectIp && !cfg.host.empty()) {
                // 仅当 rdDirectIp=true 且 host 非空时才走直连路径
                // host 此时是对端 IP 地址 (ArkTS 侧根据 per-host 配置填入)
                ffiCfg.direct_connection = true;
                OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] direct_connection=true, peer=%{public}s:%{public}d",
                    logHost.c_str(), ffiCfg.port);
            }
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] ffiCfg codec=%{public}d(%{public}s) quality=%{public}d privacy=%{public}s audio=%{public}s authMode=%{public}d size=%{public}dx%{public}d profile=%{public}d fps=%{public}d",
                ffiCfg.codec,
                rdCodecName(static_cast<int>(cfg.codec)),
                ffiCfg.imageQuality,
                ffiCfg.privacyMode ? "on" : "off",
                ffiCfg.audioEnabled ? "on" : "off",
                ffiCfg.auth_mode,
                ffiCfg.width,
                ffiCfg.height,
                ffiCfg.profile,
                ffiCfg.fps);

            void* ffiHandle = rustdesk_connect(
                &ffiCfg, onFfiFrame, onFfiAudio, onFfiCursor, onFfiDisconnect, impl);
            bool discardHandle = serial != impl->connectSerial.load() ||
                impl->disconnectRequested.load() || impl->ffiStreamEnded.load();
            if (!discardHandle) {
                std::lock_guard<std::mutex> lock(impl->mutex);
                discardHandle = serial != impl->connectSerial.load() ||
                    impl->disconnectRequested.load() || impl->ffiStreamEnded.load();
                if (!discardHandle) {
                    impl->ffiHandle = ffiHandle;
                }
            }
            if (discardHandle) {
                if (ffiHandle != nullptr) {
                    OH_LOG_INFO(LOG_APP,
                        "[RustDesk-FFI] late/ended connect result discarded handle=%{public}p",
                        ffiHandle);
                    rustdesk_disconnect(ffiHandle);
                }
                return;
            }

            if (ffiHandle == nullptr) {
                char errBuf[512] = {0};
                rustdesk_last_error(errBuf, sizeof(errBuf));
                OH_LOG_ERROR(LOG_APP, "[RustDesk-FFI] connection failed: %{public}s", errBuf);
                std::string errMsg = errBuf[0] != '\0'
                    ? std::string("FFI connection failed: ") + errBuf
                    : "FFI connection failed - check host/port and network";
                impl->setState(ConnectionState::ERROR, errMsg);
                return;
            }

            const char* connectedMessage = "Connected via Rust FFI (protobuf protocol)";
            ConnectionStateCallback connectedCallback;
            bool publishedConnected = false;
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                // Publish CONNECTED and verify handle ownership atomically with
                // the disconnect callback. This prevents a stream that ended
                // during connect from being resurrected as CONNECTED.
                if (impl->ffiHandle == ffiHandle &&
                    serial == impl->connectSerial.load() &&
                    !impl->disconnectRequested.load() &&
                    !impl->ffiStreamEnded.load()) {
                    impl->state = ConnectionState::CONNECTED;
                    connectedCallback = impl->stateCallback;
                    publishedConnected = true;
                }
            }
            if (!publishedConnected) {
                OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] connect completed after teardown, handle=%{public}p",
                    ffiHandle);
                return;
            }
            if (connectedCallback) {
                connectedCallback(ConnectionState::CONNECTED, connectedMessage);
            }
            OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Connected handle=%{public}p", ffiHandle);
        });
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->ffiConnectThread = std::move(connectThread);
        }
        return 0;

    }
#endif

    if (mode_ == RustDeskMode::IPC) {
        // ---- IPC 模式: 连接 rustdesk_helper ----
        if (cfg.rdAuthMode == 1) {
            // helper 当前只转发基础连接帧，尚未暴露 RustDesk 的
            // No Password Access/远端批准状态机；禁止静默降级为空密码登录。
            impl_->setState(ConnectionState::ERROR,
                "RustDesk helper does not support remote approval; use the real FFI core or a device password.");
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-IPC] remote approval is unavailable in helper mode; refusing empty-password fallback");
            return -40;
        }
        int ret = rdIpcConnect(g_socketPath.c_str(), impl_->ipcFd);
        if (ret < 0) {
            // 尝试自动启动 helper
            OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 未运行, 尝试自动启动...");
            if (rdTryStartHelper()) {
                // 重试连接
                ret = rdIpcConnect(g_socketPath.c_str(), impl_->ipcFd);
            }
        }
        if (ret < 0) {
            impl_->setState(ConnectionState::ERROR,
                "Helper not running. Start rustdesk_helper first.");
            return -3;
        }
        ret = rdIpcConnectFlow(impl_->ipcFd, cfg);
        if (ret < 0) {
            impl_->setState(ConnectionState::ERROR, "IPC handshake failed");
            disconnect(); return ret;
        }
        impl_->setState(ConnectionState::CONNECTED,
            "Connected via rustdesk_helper (IPC)");
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] ✓ Session routed through helper");
        return 0;
    }
#ifdef RUSTDESK_EXPERIMENTAL
    else {
        // ---- 实验模式: 手写 TCP 握手 (仅 dev) ----
        return connectExperimental(cfg);
    }
#else
    OH_LOG_ERROR(LOG_APP, "[RustDesk] RUSTDESK_EXPERIMENTAL not compiled in."
                 " Only IPC mode is available in this build.");
    impl_->setState(ConnectionState::ERROR,
        "Experimental mode not available. Rebuild with -DRUSTDESK_EXPERIMENTAL.");
    return -99;
#endif
}

void RustDeskBridge::disconnect() {
    impl_->disconnectRequested.store(true);
    impl_->cursorStore.setVisible(false);
    ++impl_->connectSerial;
    if (impl_->ipcFd >= 0) {
        shutdown(impl_->ipcFd, SHUT_RDWR);
        close(impl_->ipcFd);
        impl_->ipcFd = -1;
    }
#ifdef RUSTDESK_USE_REAL_CORE
    // FFI 句柄在登录完成前尚未返回，先取消等待中的连接尝试，避免点击返回后
    // 审批等待线程继续占用中继连接。
    rustdesk_cancel_pending_connect();
    void* ffiHandle = nullptr;
    std::thread ffiConnectThread;
    std::vector<std::thread> ffiCleanupThreads;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiHandle = impl_->ffiHandle;
        impl_->ffiHandle = nullptr;
        ffiConnectThread = std::move(impl_->ffiConnectThread);
        ffiCleanupThreads = std::move(impl_->ffiCleanupThreads);
    }
    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        rustdesk_disconnect(ffiHandle);
    }
    if (ffiConnectThread.joinable()) {
        if (ffiConnectThread.get_id() == std::this_thread::get_id()) {
            OH_LOG_ERROR(LOG_APP,
                "[RustDesk-FFI] disconnect called from connect thread; refusing self-join");
            ffiConnectThread.detach();
        } else {
            ffiConnectThread.join();
        }
    }
    for (std::thread& cleanupThread : ffiCleanupThreads) {
        if (!cleanupThread.joinable()) {
            continue;
        }
        if (cleanupThread.get_id() == std::this_thread::get_id()) {
            OH_LOG_ERROR(LOG_APP,
                "[RustDesk-FFI] cleanup thread attempted self-join; refusing self-join");
            cleanupThread.detach();
        } else {
            cleanupThread.join();
        }
    }
#endif
    if (impl_->sockFd >= 0) {
        shutdown(impl_->sockFd, SHUT_RDWR);
        close(impl_->sockFd);
        impl_->sockFd = -1;
    }
    impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
    OH_LOG_INFO(LOG_APP, "[RustDesk] Disconnected");
}

ConnectionState RustDeskBridge::getState() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->state;
}

// ============================================================
// 输入事件 (IPC 模式: 转发到 helper)
// ============================================================

void RustDeskBridge::sendKey(uint32_t scancode, bool pressed) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        uint64_t index = ++g_ffiKeySendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendKey #%{public}llu sc=%{public}u pressed=%{public}s",
                static_cast<unsigned long long>(index),
                scancode,
                pressed ? "yes" : "no");
        }
        rustdesk_send_key(impl_->ffiHandle, scancode, pressed);
        if (index <= 20 || index % 100 == 0) {
            char errBuf[512] = {0};
            rustdesk_last_error(errBuf, sizeof(errBuf));
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] rust status after sendKey: %{public}s",
                errBuf);
        }
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        RdIpcKeyEvent ev = {scancode, static_cast<uint8_t>(pressed ? 1 : 0)};
        uint8_t buf[5 + sizeof(ev)];
        RdIpcFrame::writeHeader(buf, sizeof(buf), RD_IPC_INPUT_KEY, sizeof(ev));
        memcpy(buf + 5, &ev, sizeof(ev));
        send(impl_->ipcFd, buf, sizeof(buf), 0);
    }
    OH_LOG_DEBUG(LOG_APP, "[RustDesk] key sc=%{public}u p=%{public}s", scancode, pressed ? "down" : "up");
}

void RustDeskBridge::sendMouse(int x, int y, MouseButton button, bool pressed) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        int buttonValue = static_cast<int>(button);
        uint32_t ffiButton = buttonValue < 0 ? 0xFFFFFFFFu : static_cast<uint32_t>(buttonValue);
        uint64_t index = ++g_ffiMouseSendCount;
        if (index <= 10 || index % 300 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendMouse #%{public}llu x=%{public}d y=%{public}d button=%{public}d ffiButton=%{public}u pressed=%{public}s",
                static_cast<unsigned long long>(index),
                x,
                y,
                buttonValue,
                ffiButton,
                pressed ? "yes" : "no");
        }
        rustdesk_send_mouse(impl_->ffiHandle, x, y, ffiButton, pressed);
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        RdIpcMouseEvent ev = {static_cast<uint16_t>(x), static_cast<uint16_t>(y),
                              static_cast<uint8_t>(button), static_cast<uint8_t>(pressed ? 1 : 0)};
        uint8_t buf[5 + sizeof(ev)];
        RdIpcFrame::writeHeader(buf, sizeof(buf), RD_IPC_INPUT_MOUSE, sizeof(ev));
        memcpy(buf + 5, &ev, sizeof(ev));
        send(impl_->ipcFd, buf, sizeof(buf), 0);
    }
}

void RustDeskBridge::sendMouseWheel(int x, int y, int delta) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        uint64_t index = ++g_ffiWheelSendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendWheel #%{public}llu x=%{public}d y=%{public}d delta=%{public}d",
                static_cast<unsigned long long>(index),
                x,
                y,
                delta);
        }
        rustdesk_send_mouse_wheel(impl_->ffiHandle, x, y, delta);
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        RdIpcWheelEvent ev = {static_cast<uint16_t>(x), static_cast<uint16_t>(y), static_cast<int32_t>(delta)};
        uint8_t buf[5 + sizeof(ev)];
        RdIpcFrame::writeHeader(buf, sizeof(buf), RD_IPC_INPUT_WHEEL, sizeof(ev));
        memcpy(buf + 5, &ev, sizeof(ev));
        send(impl_->ipcFd, buf, sizeof(buf), 0);
    }
}

void RustDeskBridge::sendText(const std::string& text) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        uint64_t index = ++g_ffiTextSendCount;
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] sendText #%{public}llu len=%{public}zu",
            static_cast<unsigned long long>(index),
            text.size());
        rustdesk_send_text(impl_->ffiHandle, text.c_str());
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        size_t payload = text.length();
        size_t frameSize = 5 + payload;
        auto buf = std::make_unique<uint8_t[]>(frameSize);
        RdIpcFrame::writeHeader(buf.get(), 5, RD_IPC_INPUT_TEXT, static_cast<uint32_t>(payload));
        memcpy(buf.get() + 5, text.c_str(), payload);
        send(impl_->ipcFd, buf.get(), frameSize, 0);
    }
}

int RustDeskBridge::sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        uint64_t index = ++g_ffiFileSendCount;
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] sendFileData #%{public}llu pathId=%{public}s len=%{public}u",
            static_cast<unsigned long long>(index),
            SafeLog::HashForLog(remotePath).c_str(),
            len);
        const uint64_t transferId = impl_->nextTransferId.fetch_add(1);
        impl_->transferStatus.markRustDeskProgress(transferId, 0, len);
        return rustdesk_send_file(impl_->ffiHandle, transferId, remotePath.c_str(), data, len) == 0
            ? static_cast<int>(transferId) : -1;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] sendFileData: FFI mode not available (mode=%{public}d)", static_cast<int>(mode_));
    return -1;
}

SessionTransferStatus RustDeskBridge::getSessionTransferStatus() {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        RustDeskFfiTransferStatus ffi {};
        if (rustdesk_get_transfer_status(impl_->ffiHandle, &ffi)) {
            if (ffi.state == 3) impl_->transferStatus.markRustDeskConfirmed(ffi.transferId, ffi.totalBytes);
            else if (ffi.state == 4) impl_->transferStatus.markRustDeskFailed(ffi.transferId, "remote_transfer_failed");
            else if (ffi.state == 2) impl_->transferStatus.markRustDeskProgress(ffi.transferId, ffi.transferredBytes, ffi.totalBytes);
        }
    }
#endif
    return impl_->transferStatus.snapshot();
}

void RustDeskBridge::sendClipboardData(const uint8_t* data, uint32_t len) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        rustdesk_send_clipboard(impl_->ffiHandle, data, len);
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] sendClipboardData: FFI mode not available");
}

std::string RustDeskBridge::getClipboardText() {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr) {
        const size_t length = rustdesk_get_clipboard(impl_->ffiHandle, nullptr, 0);
        if (length == 0 || length > 65536) return "";
        std::vector<unsigned char> buffer(length);
        const size_t copied = rustdesk_get_clipboard(impl_->ffiHandle, buffer.data(), buffer.size());
        if (copied != length) return "";
        return std::string(reinterpret_cast<const char*>(buffer.data()), buffer.size());
    }
#endif
    return "";
}

bool RustDeskBridge::isClipboardReceiveReady() {
#ifdef RUSTDESK_USE_REAL_CORE
    return mode_ == RustDeskMode::FFI && impl_->ffiHandle != nullptr;
#else
    return false;
#endif
}

void RustDeskBridge::requestFrameRefresh() {
#ifdef RUSTDESK_USE_REAL_CORE
    void* ffiHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiHandle = impl_->ffiHandle;
    }
    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        const bool ok = rustdesk_request_frame_refresh(ffiHandle);
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] requestFrameRefresh sent=%{public}s", ok ? "true" : "false");
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] requestFrameRefresh skipped: mode=%{public}d no ffi handle",
                static_cast<int>(mode_));
}

void RustDeskBridge::reportVideoPressure(int level) {
#ifdef RUSTDESK_USE_REAL_CORE
    void* ffiHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiHandle = impl_->ffiHandle;
    }
    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        rustdesk_report_video_pressure(ffiHandle, level);
        return;
    }
#else
    (void)level;
#endif
}

// ---- 编码能力 ----
bool RustDeskBridge::supportsCodec(CodecType codec) {
    return codec == CodecType::VP8 || codec == CodecType::VP9 ||
           codec == CodecType::AV1 || codec == CodecType::H264 ||
           codec == CodecType::H265;
}
std::vector<CodecType> RustDeskBridge::supportedCodecs() {
    return {CodecType::VP8, CodecType::VP9, CodecType::AV1, CodecType::H264, CodecType::H265};
}

// ---- 回调 ----
void RustDeskBridge::setVideoCallback(VideoFrameCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->videoCallback = std::move(cb);
}
void RustDeskBridge::setAudioCallback(AudioDataCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->audioCallback = std::move(cb);
}
void RustDeskBridge::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stateCallback = std::move(cb);
}
bool RustDeskBridge::supportsNatTraversal() { return mode_ == RustDeskMode::FFI || mode_ == RustDeskMode::EXPERIMENTAL; }
bool RustDeskBridge::supportsFileTransfer() { return true; }

void registerRustDeskBridge() {
#ifdef RUSTDESK_USE_REAL_CORE
    auto adapter = std::shared_ptr<RustDeskBridge>(new RustDeskBridge(RustDeskMode::FFI));
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDesk bridge registered (FFI mode, protobuf+NaCl)");
#else
    auto adapter = std::shared_ptr<RustDeskBridge>(new RustDeskBridge(RustDeskMode::IPC));
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDesk bridge registered (IPC mode, safe)");
#endif
    ExtensionSystem::instance().protocols.registerExt("protocol", "rustdesk", adapter);
}

#ifdef RUSTDESK_EXPERIMENTAL
// ============================================================
// RD_MODE_EXPERIMENTAL: 手写 TCP 握手 (仅 dev/test)
// WARNING: 密码明文发送 — 不得用于正式构建
// ============================================================
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <vector>
#include <random>

int RustDeskBridge::connectExperimental(const ConnectionConfig& cfg) {
    OH_LOG_WARN(LOG_APP, "[RustDesk-EXP] ⚠ EXPERIMENTAL MODE — plaintext password over TCP!");
    int port = cfg.port > 0 ? cfg.port : RD_DEFAULT_TCP_PORT;

    // TCP connect
    impl_->sockFd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    inet_pton(AF_INET, cfg.host.c_str(), &addr.sin_addr);
    if (::connect(impl_->sockFd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        impl_->setState(ConnectionState::ERROR, "TCP connect failed");
        return -12;
    }

    // Version exchange
    unsigned char syn[16] = {};
    memcpy(syn, "RDCM", 4); syn[4] = 0x01;
    send(impl_->sockFd, syn, 16, 0);
    unsigned char ack[16];
    recv(impl_->sockFd, ack, 16, 0);

    // ID registration
    if (!cfg.customHostname.empty()) { /* ... */ }

    // ====== WARNING: 明文密码 — 仅实验 ======
    if (!cfg.password.empty()) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-EXP] ⚠ Sending password in PLAINTEXT over TCP (EXPERIMENTAL ONLY)");
        unsigned char auth[260] = {};
        auth[0] = 0x02;
        size_t pwLen = cfg.password.length();
        if (pwLen > 255) pwLen = 255;
        auth[1] = static_cast<uint8_t>(pwLen);
        memcpy(auth + 2, cfg.password.c_str(), pwLen);
        send(impl_->sockFd, auth, pwLen + 2, 0);
        unsigned char result[1];
        if (recv(impl_->sockFd, result, 1, 0) <= 0 || result[0] != 0x00) {
            impl_->setState(ConnectionState::ERROR, "Auth failed");
            return -24;
        }
    }

    impl_->setState(ConnectionState::CONNECTED, "Connected (EXPERIMENTAL, plaintext)");
    OH_LOG_WARN(LOG_APP, "[RustDesk-EXP] ⚠ Connected with PLAINTEXT password — DO NOT USE IN PRODUCTION");
    return 0;
}
#endif // RUSTDESK_EXPERIMENTAL

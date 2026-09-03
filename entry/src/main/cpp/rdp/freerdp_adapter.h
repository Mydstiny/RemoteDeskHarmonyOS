/**
 * freerdp_adapter.h — FreeRDP 协议适配器声明
 *
 * 双路径架构:
 *   #ifdef USE_REAL_FREERDP — 真实 FreeRDP 3.x 客户端 (需交叉编译 libfreerdp3.a)
 *   #else                     — 手写 RDP 骨架 (当前可用, 仅 TCP/RDP Negotiation/MCS)
 */

#ifndef FREERDP_ADAPTER_H
#define FREERDP_ADAPTER_H

#include "extensions/protocol_adapter.h"
#include "render/video_perf_counters.h"
#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#ifdef USE_REAL_FREERDP
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/event.h>
#include <freerdp/graphics.h>
#include <freerdp/client/cliprdr.h>
#if defined(CHANNEL_DISP_CLIENT)
#include <freerdp/client/disp.h>
#endif
#include <freerdp/version.h>
#endif

// 前向声明 — FreeRdpContext 需要引用 FreeRdpAdapter
class FreeRdpAdapter;

#ifdef USE_REAL_FREERDP
class RdpTeardownReservations;

/**
 * FreeRDP 3.x 自定义上下文 — 在 rdpContext 后嵌入 adapter 回指针
 * FreeRDP 3.x 要求设置 ContextSize 并通过 freerdp_context_new() 分配.
 */
struct FreeRdpContext {
	rdpContext base;           // MUST be first — FreeRDP 内部以此访问 rdpContext
	FreeRdpAdapter* adapter;  // 回指针，供回调中使用
	uint64_t generation = 0;   // connection generation that owns this context
	Render::DecoderSessionIdentity owner;
};
#endif

class FreeRdpAdapter : public ProtocolAdapter,
                       public std::enable_shared_from_this<FreeRdpAdapter> {
public:
    using RdpVideoTelemetryCallback = std::function<void(
        int width, int height, size_t bytes, bool submitted)>;

    FreeRdpAdapter();
    ~FreeRdpAdapter() override;

    // ---- 协议元信息 ----
    std::string protocolName() override;
    int         defaultPort() override;
    std::string protocolVersion() override;

    // ---- 连接管理 ----
    int             connect(const ConnectionConfig& cfg) override;
    void            disconnect() override;
    ConnectionState getState() override;
    void            onNetworkChanged(bool available, uint64_t networkGeneration) override;
    void            setSessionIdentity(uint64_t sessionId) override;
    void            setSessionOwner(const Render::DecoderSessionIdentity& owner);
    // Used by static FreeRDP ABI entries immediately before platform
    // side-effects, after their captured admission lease was acquired.
    bool isCallbackOwnerCurrent(const Render::DecoderSessionIdentity& owner,
                                uint64_t callbackGeneration) const;
    RemoteCursorSnapshot getRemoteCursorSnapshot(bool includePixels) override;
    void            requestFrameRefresh() override;
    RdpCertificateInfo probeRdpCertificate(const std::string& host, int port,
                                           const std::string& serverName,
                                           const std::function<bool()>& cancelled = {}) override;
    RdpPreflightResult probeRdpCertificateRoute(const RdpPreflightRequest& request) override;
    RdpRenderStats  getRdpRenderStats() override;
    bool            acknowledgeRdpInputGeometry(uint64_t epoch, int width, int height) override;
    bool            synchronizeRendererGeometry();
    RdpDisplayLayoutResult requestDisplayLayout(const RdpDisplayLayoutRequest& request);
    bool            cancelDisplayLayout();
    bool            setBackgroundVideoPrewarm(bool enabled, uint32_t intervalMs);
    bool            presentCachedBackgroundFrame();

    // ---- 输入事件 ----
    void sendKey(uint32_t scancode, bool pressed) override;
    void sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void sendMouseWheel(int x, int y, int delta) override;
    void sendText(const std::string& text) override;

    // ---- 编码能力 ----
    bool supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;

    // ---- 回调注册 ----
    void setVideoCallback(VideoFrameCallback callback) override;
    void setVideoTelemetryCallback(RdpVideoTelemetryCallback callback);
    void setAudioCallback(AudioDataCallback callback) override;
    void setConnectionStateCallback(ConnectionStateCallback callback) override;

    // ---- 扩展功能 ----
    void        setClipboardText(const std::string& text) override;
    bool        setClipboardFiles(const std::vector<std::string>& paths) override;
    void        sendClipboardData(const uint8_t* data, uint32_t len) override;
    std::string getClipboardText() override;
    bool        isClipboardReceiveReady() override;
    bool        setSessionClipboardEnabled(bool enabled) override;
    bool        supportsFileTransfer() override;
    SessionTransferStatus getSessionTransferStatus() override;

#if defined(RDP_NATIVE_CALLBACK_TESTING) && defined(USE_REAL_FREERDP)
    void SetEndPaintBarrierForTesting(std::function<void()> barrier);
    static BOOL InvokeEndPaintCallbackForTesting(rdpContext* context) {
        return cbEndPaint(context);
    }
    static BOOL InvokeEndPaintCallbackForTestingWithToken(
        rdpContext* context, uint64_t capturedToken) {
        return cbEndPaintWithExpectedToken(context, capturedToken);
    }
    static void InvokePostDisconnectCallbackForTesting(rdpContext* context) {
        if (!context) {
            return;
        }
        freerdp instance {};
        instance.context = context;
        cbPostDisconnect(&instance);
    }
    // Invoke every callback family through its production static entry after
    // the carrier has been retired.  The helper intentionally returns only
    // the fail-closed result of entries with a return value; void callbacks
    // are still executed to prove they do not dereference the retired
    // context.  It is test-only and does not add a production ABI symbol.
    static bool InvokeRetiredCallbackFamilyForTesting(rdpContext* context) {
        if (!context) {
            return true;
        }
        freerdp instance {};
        instance.context = context;
        ChannelConnectedEventArgs connected {};
        ChannelDisconnectedEventArgs disconnected {};
        cbErrorInfo(context, nullptr);
        cbChannelConnected(context, &connected);
        cbChannelDisconnected(context, &disconnected);
        cbPointerFree(context, nullptr);
        cbPointerNew(context, nullptr);
        cbPointerSet(context, nullptr);
        cbPointerSetPosition(context, 0, 0);
        cbPointerSetNull(context);
        cbPointerSetDefault(context);
        cbBeginPaint(context);
        cbDesktopResize(context);
        cbLoadChannels(&instance);
        cbPostConnect(&instance);
        cbPostDisconnect(&instance);
        return cbLogonErrorInfo(&instance, 0, 0) == 0 &&
            cbVerifyCertificate(&instance, nullptr, nullptr, nullptr, nullptr, FALSE) == 0 &&
            cbVerifyCertificateEx(&instance, nullptr, 0, nullptr, nullptr, nullptr,
                                  nullptr, 0) == 0 &&
            cbVerifyChangedCertificateEx(&instance, nullptr, 0, nullptr, nullptr,
                                         nullptr, nullptr, nullptr, nullptr, nullptr, 0) == 0 &&
            cbVerifyX509Certificate(&instance, nullptr, 0, nullptr, 0, 0) == 0;
    }
    static uint64_t CallbackContextTokenForTesting(rdpContext* context);
    static bool RegisterCallbackContextForTesting(
        rdpContext* context, FreeRdpAdapter* adapter,
        const Render::DecoderSessionIdentity& owner, uint64_t generation);
    static bool RegisterCallbackContextForTesting(
        freerdp* instance, rdpContext* context, FreeRdpAdapter* adapter,
        const Render::DecoderSessionIdentity& owner, uint64_t generation);
    static void UnregisterCallbackContextForTesting(rdpContext* context);
    // Install every instance-owned callback slot on a real FreeRDP carrier so
    // the production revoke helper can be checked against the actual ABI.
    static bool InstallCallbackSourcesForTesting(freerdp* instance);
    // Test-only proof that the platform callback source has been unregistered
    // and quiesced; production retirement releases this quarantine only after
    // final instance cleanup.
    static bool RevokeCallbackSourcesForTesting(rdpContext* context);
    static bool RevokeCallbackSourcesForTesting(
        freerdp* instance, rdpContext* context,
        CliprdrClientContext* cliprdr = nullptr);
    static bool ReleaseCallbackSourceQuarantineForTesting(rdpContext* context);
    static bool ReleaseCallbackSourceQuarantineForTesting(
        freerdp* instance, rdpContext* context);
    uint64_t ShutdownTicketSerialForTesting() const;
    static void SetRdpsndCallbackForTesting(
        AudioDataCallback callback, const Render::DecoderSessionIdentity& owner);
    static void ClearRdpsndCallbackForTesting(
        const Render::DecoderSessionIdentity& owner);
    static uint64_t RdpsndCallbackTokenForTesting();
    static UINT InvokeRdpsndCallbackForTestingWithToken(
        uint64_t capturedToken, const BYTE* data, size_t size,
        UINT32 sampleRate, UINT16 channels, UINT16 bitsPerSample);
    static std::shared_ptr<std::atomic<bool>> QueueBlockedWorkerForTesting();
    static bool VerifyTeardownCarrierIsolationForTesting();
    static bool DrainDeferredWorkersWithinForTesting(uint32_t timeoutMs);
    static bool ShutdownDeferredWorkersWithinForTesting(uint32_t timeoutMs);
    static std::size_t DeferredWorkerRemainingForTesting();
#endif

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    int connectInternal(const ConnectionConfig& cfg, uint64_t networkActionToken);
    void disconnectInternal(bool publishDisconnected = true);

#ifdef USE_REAL_FREERDP
    // FreeRDP 客户端实例 + 事件循环
    freerdp*  instance_ = nullptr;
    std::atomic<bool> eventLoopRunning_ {false};

    bool startEventLoop();
    void stopEventLoop(std::chrono::steady_clock::time_point deadline);
    void processEventLoop();
    void joinConnectThread(std::chrono::steady_clock::time_point deadline);
    void joinDriveThread(std::chrono::steady_clock::time_point deadline);
    bool disconnectActiveInstance(
        std::chrono::steady_clock::time_point deadline,
        const std::shared_ptr<RdpTeardownReservations>& teardownReservations);
    void cleanupInstance(std::chrono::steady_clock::time_point deadline =
                             std::chrono::steady_clock::time_point::max(),
                         uint64_t expectedGeneration = 0,
                         std::shared_ptr<RdpTeardownReservations>
                             teardownReservations = nullptr);
    void connectThreadFunc(uint64_t expectedGeneration,
                           uint64_t expectedNetworkGeneration,
                           const std::shared_ptr<RdpTeardownReservations>&
                               teardownReservations); // async connect worker
    void startDriveMountAfterConnected(const std::string& driveName,
                                       const std::string& drivePath,
                                       uint64_t generation);
    void mountDriveAfterConnected(const std::string& driveName,
                                  const std::string& drivePath,
                                  uint64_t generation);
    DWORD evaluateCertificate(const char* host, UINT16 port, const char* commonName,
                              const char* subject, const char* issuer,
                              const std::string& fingerprint, DWORD flags,
                              const BYTE* pemData = nullptr, size_t pemLength = 0);
    void queuePostDisconnectTeardown();

    // FreeRDP PreConnect 阶段加载 rdpsnd/rdpdr/cliprdr 等客户端通道
    static BOOL cbLoadChannels(freerdp* instance);

    // GFX/BeginPaint callbacks → GDI raw BGRA → GLRenderer
    static BOOL cbPostConnect(freerdp* instance);
    static void cbPostDisconnect(freerdp* instance);
    static BOOL cbBeginPaint(rdpContext* context);
    static BOOL cbEndPaint(rdpContext* context);
    static BOOL cbEndPaintWithExpectedToken(rdpContext* context, uint64_t expectedToken);
    static BOOL cbDesktopResize(rdpContext* context);
    static BOOL cbPointerNew(rdpContext* context, rdpPointer* pointer);
    static void cbPointerFree(rdpContext* context, rdpPointer* pointer);
    static BOOL cbPointerSet(rdpContext* context, rdpPointer* pointer);
    static BOOL cbPointerSetPosition(rdpContext* context, UINT32 x, UINT32 y);
    static BOOL cbPointerSetNull(rdpContext* context);
    static BOOL cbPointerSetDefault(rdpContext* context);
    static DWORD WINAPI cbVerifyCertificate(freerdp* instance, const char* common_name,
                                            const char* subject, const char* issuer,
                                            const char* fingerprint, BOOL host_mismatch);
    static DWORD cbVerifyCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                       const char* common_name, const char* subject,
                                       const char* issuer, const char* fingerprint, DWORD flags);
    static DWORD cbVerifyChangedCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                              const char* common_name, const char* subject,
                                              const char* issuer, const char* new_fingerprint,
                                              const char* old_subject, const char* old_issuer,
                                              const char* old_fingerprint, DWORD flags);
    static int cbVerifyX509Certificate(freerdp* instance, const BYTE* data, size_t length,
                                       const char* hostname, UINT16 port, DWORD flags);
    static int cbLogonErrorInfo(freerdp* instance, UINT32 data, UINT32 type);
    static void cbErrorInfo(void* context, const ErrorInfoEventArgs* e);
    static void cbChannelConnected(void* context, const ChannelConnectedEventArgs* e);
    static void cbChannelDisconnected(void* context, const ChannelDisconnectedEventArgs* e);
#if defined(CHANNEL_DISP_CLIENT)
    static UINT cbDisplayControlCaps(DispClientContext* context, UINT32 maxNumMonitors,
                                     UINT32 maxMonitorAreaFactorA,
                                     UINT32 maxMonitorAreaFactorB);
#endif
    static UINT cbCliprdrMonitorReady(CliprdrClientContext* context, const CLIPRDR_MONITOR_READY* ready);
    static UINT cbCliprdrServerCapabilities(CliprdrClientContext* context,
                                           const CLIPRDR_CAPABILITIES* capabilities);
    static UINT cbCliprdrServerFormatList(CliprdrClientContext* context, const CLIPRDR_FORMAT_LIST* list);
    static UINT cbCliprdrServerFormatDataRequest(CliprdrClientContext* context,
                                                const CLIPRDR_FORMAT_DATA_REQUEST* request);
    static UINT cbCliprdrServerFormatDataResponse(CliprdrClientContext* context,
                                                 const CLIPRDR_FORMAT_DATA_RESPONSE* response);
#endif
};

/** 在扩展系统中注册 FreeRDP 适配器 */
void registerFreeRdpAdapter();

#endif // FREERDP_ADAPTER_H

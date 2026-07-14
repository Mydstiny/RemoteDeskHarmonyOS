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
#include <atomic>
#include <memory>
#ifdef USE_REAL_FREERDP
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/event.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/version.h>
#endif

// 前向声明 — FreeRdpContext 需要引用 FreeRdpAdapter
class FreeRdpAdapter;

#ifdef USE_REAL_FREERDP
/**
 * FreeRDP 3.x 自定义上下文 — 在 rdpContext 后嵌入 adapter 回指针
 * FreeRDP 3.x 要求设置 ContextSize 并通过 freerdp_context_new() 分配.
 */
struct FreeRdpContext {
	rdpContext base;           // MUST be first — FreeRDP 内部以此访问 rdpContext
	FreeRdpAdapter* adapter;  // 回指针，供回调中使用
};
#endif

class FreeRdpAdapter : public ProtocolAdapter {
public:
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
    void            requestFrameRefresh() override;
    RdpCertificateInfo probeRdpCertificate(const std::string& host, int port,
                                           const std::string& serverName) override;
    RdpRenderStats  getRdpRenderStats() override;
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
    void setAudioCallback(AudioDataCallback callback) override;
    void setConnectionStateCallback(ConnectionStateCallback callback) override;

    // ---- 扩展功能 ----
    void        setClipboardText(const std::string& text) override;
    void        sendClipboardData(const uint8_t* data, uint32_t len) override;
    std::string getClipboardText() override;
    bool        isClipboardReceiveReady() override;
    bool        supportsFileTransfer() override;
    SessionTransferStatus getSessionTransferStatus() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

#ifdef USE_REAL_FREERDP
    // FreeRDP 客户端实例 + 事件循环
    freerdp*  instance_ = nullptr;
    std::atomic<bool> eventLoopRunning_ {false};

    void startEventLoop();
    void stopEventLoop();
    void processEventLoop();
    void joinConnectThread();
    void joinDriveThread();
    void abortActiveConnection();
    void disconnectActiveInstance();
    void cleanupInstance();
    void connectThreadFunc();    // 连接线程 (异步, 不阻塞 NAPI)
    void startDriveMountAfterConnected(const std::string& driveName, const std::string& drivePath);
    void mountDriveAfterConnected(const std::string& driveName, const std::string& drivePath);
    DWORD evaluateCertificate(const char* host, UINT16 port, const char* commonName,
                              const char* subject, const char* issuer,
                              const std::string& fingerprint, DWORD flags);

    // FreeRDP PreConnect 阶段加载 rdpsnd/rdpdr/cliprdr 等客户端通道
    static BOOL cbLoadChannels(freerdp* instance);

    // GFX/BeginPaint callbacks → GDI raw BGRA → GLRenderer
    static BOOL cbPostConnect(freerdp* instance);
    static void cbPostDisconnect(freerdp* instance);
    static BOOL cbBeginPaint(rdpContext* context);
    static BOOL cbEndPaint(rdpContext* context);
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
    static UINT cbCliprdrMonitorReady(CliprdrClientContext* context, const CLIPRDR_MONITOR_READY* ready);
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

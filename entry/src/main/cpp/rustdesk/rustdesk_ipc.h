/**
 * rustdesk_ipc.h — RustDesk Helper IPC 协议定义
 *
 * 设计目标:
 *   - 主进程通过 Unix Domain Socket 与独立 rustdesk_helper 进程通信
 *   - 避免主进程直接处理 RustDesk 私有协议 → AGPL 许可证隔离
 *   - 密码/密钥通过 IPC 加密通道传输, 不出现在主进程 TCP 层
 *
 * 帧格式 (小端字节序):
 *   [4 bytes payload_size (uint32_t)] [1 byte msg_type] [N bytes payload]
 *
 * 最大帧大小: 4 MB (支持视频帧传输)
 */

#ifndef RUSTDESK_IPC_H
#define RUSTDESK_IPC_H

#include <cstdint>
#include <string>

// ---- IPC 常量 ----
// 默认路径仅在 helper 由外部启动时使用; App 内启动时由 ArkTS setHelperSocketPath() 覆盖
#define RD_IPC_SOCKET_PATH_DEFAULT  "/data/local/tmp/rustdesk_helper.sock"
#define RD_IPC_MAX_FRAME_SIZE       (4 * 1024 * 1024)  // 4 MB
// 运行时 socket 路径 (setHelperSocketPath NAPI 可覆盖)
extern const char* g_rustdeskHelperSocketPath;
void rdSetHelperSocketPath(const char* path);
#define RD_IPC_MAX_PAYLOAD     (RD_IPC_MAX_FRAME_SIZE - 5)

// ---- 消息类型 ----
enum RdIpcMsgType : uint8_t {
    // 连接管理 (0x00–0x0F)
    RD_IPC_CONNECT_REQ    = 0x01,  // 连接请求: {host, port, id, password}
    RD_IPC_CONNECT_ACK    = 0x02,  // 连接确认: {state, error}
    RD_IPC_DISCONNECT     = 0x03,  // 断开连接

    // 输入事件 (0x10–0x1F)
    RD_IPC_INPUT_KEY      = 0x10,  // 键盘: {scancode(4), pressed(1)}
    RD_IPC_INPUT_MOUSE    = 0x11,  // 鼠标: {x(2), y(2), button(1), pressed(1)}
    RD_IPC_INPUT_WHEEL    = 0x12,  // 滚轮: {x(2), y(2), delta(4)}
    RD_IPC_INPUT_TEXT     = 0x13,  // 文本: {utf8_string}

    // 媒体流 (0x20–0x2F)
    RD_IPC_VIDEO_FRAME    = 0x20,  // 视频帧: {data, size, width, height, codec, timestamp, keyframe}
    RD_IPC_AUDIO_DATA     = 0x21,  // 音频: {data, size, sample_rate, channels, timestamp}

    // 数据通道 (0x30–0x3F)
    RD_IPC_CLIPBOARD_SET  = 0x30,  // 设置剪贴板: {text}
    RD_IPC_CLIPBOARD_GET  = 0x31,  // 获取剪贴板
    RD_IPC_FILE_TRANSFER  = 0x32,  // 文件传输请求

    // 状态/控制 (0xF0–0xFF)
    RD_IPC_STATE_CHANGE   = 0xF0,  // 连接状态变更: {state(4), error_msg}
    RD_IPC_PING           = 0xFE,  // 心跳探测
    RD_IPC_PONG           = 0xFF,  // 心跳响应
};

// ---- 连接请求 payload 结构 (RD_IPC_CONNECT_REQ) ----
struct RdIpcConnectReq {
    char     host[256];      // 远程主机/IP
    uint32_t port;           // 端口号
    char     peerId[128];    // RustDesk 远程 ID
    char     username[128];  // 用户名
    uint32_t passwordLen;    // 密码长度
    // password 数据紧随其后 (推荐在 helper 侧用官方认证链, 不通过主进程 TCP)
    uint32_t width;          // 期望宽度
    uint32_t height;         // 期望高度
    uint32_t codec;          // 0=H264, 1=H265, 2=VP8, 3=VP9, 4=AV1
    uint32_t imageQuality;   // 0=速度, 1=平衡, 2=画质
    uint32_t directIp;       // 0=中继/ID, 1=直连 IP
    uint32_t directPort;     // 直连端口
    uint32_t lanDiscovery;   // 0=关闭, 1=开启
    uint32_t privacyMode;    // 0=关闭, 1=开启
    uint32_t passwordMode;   // 0=一次性, 1=永久
    uint32_t passwordLength; // 临时密码长度
    char     relayId[128];   // 绑定中继配置 ID
    char     accountId[128]; // 绑定 API 账户 ID
};

// ---- 输入事件 payload ----
struct RdIpcKeyEvent {
    uint32_t scancode;
    uint8_t  pressed;   // 0=release, 1=press
};

struct RdIpcMouseEvent {
    uint16_t x;
    uint16_t y;
    uint8_t  button;    // 0=left, 1=right, 2=middle
    uint8_t  pressed;
};

struct RdIpcWheelEvent {
    uint16_t x;
    uint16_t y;
    int32_t  delta;
};

// ---- 视频帧 payload ----
struct RdIpcVideoFrameHdr {
    uint32_t dataSize;
    uint32_t width;
    uint32_t height;
    uint32_t codec;     // 0=H264, 1=H265, 2=VP8, 3=VP9
    uint64_t timestamp;  // 微秒
    uint8_t  isKeyFrame;
    // frame data 紧随其后
};

// ---- IPC 帧序列化/反序列化 ----
namespace RdIpcFrame {

/** 写入帧头到 buffer, 返回写入字节数 */
inline size_t writeHeader(uint8_t* buf, size_t bufSize, RdIpcMsgType type, uint32_t payloadSize) {
    if (bufSize < 5) { return 0; }
    // Little-endian payload size
    buf[0] = static_cast<uint8_t>(payloadSize & 0xFF);
    buf[1] = static_cast<uint8_t>((payloadSize >> 8) & 0xFF);
    buf[2] = static_cast<uint8_t>((payloadSize >> 16) & 0xFF);
    buf[3] = static_cast<uint8_t>((payloadSize >> 24) & 0xFF);
    buf[4] = static_cast<uint8_t>(type);
    return 5;
}

/** 读取帧头, 返回 payload 大小; msgType 由调用方接收 */
inline bool readHeader(const uint8_t* buf, size_t bufSize,
                       RdIpcMsgType& msgType, uint32_t& payloadSize) {
    if (bufSize < 5) { return false; }
    payloadSize = static_cast<uint32_t>(buf[0]) |
                  (static_cast<uint32_t>(buf[1]) << 8) |
                  (static_cast<uint32_t>(buf[2]) << 16) |
                  (static_cast<uint32_t>(buf[3]) << 24);
    msgType = static_cast<RdIpcMsgType>(buf[4]);
    return payloadSize <= RD_IPC_MAX_PAYLOAD;
}

} // namespace RdIpcFrame

#endif // RUSTDESK_IPC_H

#pragma once

#include <cstdint>
#include <functional>
#include <string>

// 编解码器类型
enum class CodecType {
    H264,
    H265,
    VP8,
    VP9,
    UNKNOWN
};

// 连接配置
struct ConnectionConfig {
    std::string host;           // IP 或域名
    int port = 3389;            // 端口号
    std::string username;       // 登录用户名
    std::string password;       // 登录密码
    std::string domain;         // Windows 域（RDP NLA 认证使用）
    int width = 1920;           // 远程桌面宽度
    int height = 1080;          // 远程桌面高度
    int fps = 30;               // 目标帧率
    bool enableAudio = true;    // 是否启用音频
    bool enableClipboard = true;// 是否启用剪贴板共享
};

// 视频帧数据结构
struct VideoFrame {
    const uint8_t* data = nullptr;
    size_t size = 0;
    int width = 0;
    int height = 0;
    int stride = 0;
    CodecType codec = CodecType::H264;
    int64_t timestamp = 0;
};

// 音频数据块结构
struct AudioData {
    const uint8_t* data = nullptr;
    size_t size = 0;
    int sampleRate = 48000;
    int channels = 2;
    int64_t timestamp = 0;
};

using VideoFrameCallback = std::function<void(const VideoFrame&)>;
using AudioDataCallback = std::function<void(const AudioData&)>;

// 连接回调集合
struct ConnectionCallbacks {
    VideoFrameCallback onVideoFrame;         // 视频帧到达回调
    AudioDataCallback onAudioData;           // 音频数据到达回调
    std::function<void(int, const std::string&)> onError;       // 错误回调
    std::function<void()> onDisconnected;    // 断开连接回调
};

// ProtocolAdapter 接口 — 所有远程协议适配器必须实现的纯虚接口
class ProtocolAdapter {
public:
    virtual ~ProtocolAdapter() = default;

    virtual std::string protocol_name() = 0;       // 协议名称："RDP", "RustDesk"
    virtual std::string protocol_version() = 0;    // 协议版本号
    virtual int default_port() = 0;                // 默认端口：3389 / 21116

    virtual int connect(const ConnectionConfig& cfg, ConnectionCallbacks* cb) = 0;
    virtual void disconnect() = 0;
    virtual bool is_connected() = 0;

    virtual void send_key(uint32_t scancode, bool pressed) = 0;
    virtual void send_mouse(int x, int y, int button, bool pressed) = 0;
    virtual void send_text(const std::string& text) = 0;

    virtual bool supports_codec(CodecType codec) = 0;

    virtual void set_video_callback(VideoFrameCallback cb) = 0;
    virtual void set_audio_callback(AudioDataCallback cb) = 0;
};

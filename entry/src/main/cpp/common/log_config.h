/**
 * log_config.h — 日志级别配置
 *
 * 编译期 + 运行时日志过滤.
 *
 * 默认策略:
 *   - ERROR/WARN:     始终输出
 *   - INFO:           仅状态变更 (connect/disconnect/stream start)
 *   - DEBUG:          默认关闭 (帧级日志禁用)
 *   - RDP_LOG_VERBOSE: 编译宏, 开启帧级 DEBUG 输出 (仅 dev)
 *
 * 使用:
 *   #include "common/log_config.h"
 *   RDP_LOG_INFO(LOG_APP, "[TAG] state changed: %{public}d", state);
 *   // DEBUG 帧级日志仅在 RDP_LOG_VERBOSE 宏定义时输出:
 *   RDP_LOG_FRAME(LOG_APP, "[TAG] frame %{public}llu", ts);
 */

#ifndef LOG_CONFIG_H
#define LOG_CONFIG_H

#include <hilog/log.h>
#include <atomic>

namespace LogConfig {

enum class Level : uint8_t {
    OFF = 0,
    ERROR = 1,
    WARN = 2,
    INFO = 3,
    DEBUG = 4,
    VERBOSE = 5,
};

// 全局最低日志级别 (运行时可变)
inline std::atomic<Level> g_minLevel{Level::INFO};

inline void setLevel(Level level) { g_minLevel.store(level); }
inline Level getLevel() { return g_minLevel.load(); }

} // namespace LogConfig

// ---- 条件日志宏 ----

// INFO: 状态变更用
#define RDP_LOG_INFO(type, fmt, ...) \
    do { if (LogConfig::g_minLevel.load() >= LogConfig::Level::INFO) \
        OH_LOG_INFO(type, fmt, ##__VA_ARGS__); } while(0)

// WARN: 始终输出
#define RDP_LOG_WARN(type, fmt, ...) \
    OH_LOG_WARN(type, fmt, ##__VA_ARGS__)

// ERROR: 始终输出
#define RDP_LOG_ERROR(type, fmt, ...) \
    OH_LOG_ERROR(type, fmt, ##__VA_ARGS__)

// DEBUG: 仅在 RDP_LOG_VERBOSE 编译宏下输出
#ifdef RDP_LOG_VERBOSE
#define RDP_LOG_DEBUG(type, fmt, ...) \
    OH_LOG_DEBUG(type, fmt, ##__VA_ARGS__)
#define RDP_LOG_FRAME(type, fmt, ...) \
    OH_LOG_DEBUG(type, fmt, ##__VA_ARGS__)
#else
#define RDP_LOG_DEBUG(type, fmt, ...) ((void)0)
#define RDP_LOG_FRAME(type, fmt, ...) ((void)0)
#endif

#endif // LOG_CONFIG_H

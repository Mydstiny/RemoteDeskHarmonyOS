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
#include "rustdesk_display_control_plane.h"
#include "rustdesk_ipc.h"
#include "audio/audio_player.h"
#include "common/safe_log.h"
#include "extensions/extension_registry.h"
#include "render/video_perf_counters.h"
#include <hilog/log.h>
#include <algorithm>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <future>
#include <functional>
#include <memory>
#include <set>
#include <string>
#include <thread>

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
    void* rustdesk_connect_v2(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void* user_data);
    void* rustdesk_connect_v3(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void (*on_auth)(int, const char*, void*),
        void* user_data);
    struct RustDeskFfiTransportEvent {
        int state;
        const char* errorClass;
        uint64_t networkGeneration;
        bool userInitiated;
    };
    void* rustdesk_connect_v4(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void (*on_auth)(int, const char*, void*),
        void (*on_transport_event)(const void*, void*),
        void* user_data);
    void  rustdesk_disconnect(void* handle);
    uint32_t rustdesk_quiesce_session(void* handle);
    void  rustdesk_cancel_pending_connect();
    void  rustdesk_cancel_pending_connect_for_session(uint64_t session_id);
    void  rustdesk_shutdown_deferred_joiner();
    bool  rustdesk_submit_2fa(const char* code);
    bool  rustdesk_submit_2fa_for_session(uint64_t session_id, const char* code);
    void  rustdesk_send_key(void* handle, unsigned int scancode, bool pressed);
    void  rustdesk_send_mouse(void* handle, int x, int y, unsigned int button, bool pressed);
    void  rustdesk_send_mouse_wheel(void* handle, int x, int y, int delta);
    void  rustdesk_send_text(void* handle, const char* text);
    bool  rustdesk_change_display_resolution(void* handle, int display, int width, int height);
    bool  rustdesk_send_touch_scale(void* handle, int scale);
    bool  rustdesk_send_touch_pan(void* handle, int phase, int x, int y);
    int   rustdesk_send_file(void* handle, uint64_t transfer_id, const char* remote_path,
                             const unsigned char* data, unsigned int len);
    struct RustDeskFfiTransferStatus { uint32_t state; uint64_t transferId; uint64_t transferredBytes;
        uint64_t totalBytes; uint32_t diagnosticCode; };
    bool  rustdesk_get_transfer_status(void* handle, RustDeskFfiTransferStatus* out_status);
    void  rustdesk_send_clipboard(void* handle, const unsigned char* data, unsigned int len);
    size_t rustdesk_get_clipboard(void* handle, unsigned char* buffer, size_t buffer_len);
    bool  rustdesk_request_frame_refresh(void* handle);
    bool  rustdesk_report_video_pressure(void* handle, int level);
    struct RustDeskFfiStreamStats {
        uint32_t version;
        uint32_t state;
        uint32_t last_delay_ms;
        uint32_t target_bitrate_kbps;
        uint64_t video_messages;
        uint64_t video_frames;
        uint64_t keyframes;
        uint64_t encoded_bytes;
        uint64_t audio_frames;
        uint64_t cadence_gaps;
        uint64_t max_cadence_gap_ms;
        uint64_t test_delay_count;
        int32_t actual_codec;
        int32_t width;
        int32_t height;
        int32_t connection_path;
    };
    bool  rustdesk_get_stream_stats(void* handle, RustDeskFfiStreamStats* out_stats);
    struct RustDeskFfiDisplaySnapshot {
        uint32_t version;
        int32_t currentDisplay;
        int32_t width;
        int32_t height;
        int32_t originalWidth;
        int32_t originalHeight;
        int32_t scaleMilli;
        uint32_t geometryEpoch;
        uint32_t resolutionCount;
    };
    struct RustDeskFfiResolution { int32_t width; int32_t height; };
    struct RustDeskFfiDisplayInfoSnapshot {
        int32_t display;
        int32_t x;
        int32_t y;
        int32_t width;
        int32_t height;
        int32_t originalWidth;
        int32_t originalHeight;
        int32_t scaleMilli;
        uint8_t online;
        uint8_t cursorEmbedded;
        uint8_t reserved[2];
        uint32_t nameLen;
        uint8_t name[128];
        uint32_t resolutionOffset;
        uint32_t resolutionCount;
    };
    bool  rustdesk_get_display_snapshot(void* handle, RustDeskFfiDisplaySnapshot* out_snapshot,
                                        RustDeskFfiResolution* out_resolutions, size_t capacity);
    bool  rustdesk_get_display_list(void* handle, RustDeskFfiDisplayInfoSnapshot* out_displays,
                                    size_t display_capacity, RustDeskFfiResolution* out_resolutions,
                                    size_t resolution_capacity, size_t* out_display_count,
                                    size_t* out_resolution_count);
    bool  rustdesk_switch_display(void* handle, int display);
    bool  rustdesk_capture_displays(void* handle, const int* displays, size_t count);
    bool  rustdesk_refresh_video_display(void* handle, int display);
    size_t rustdesk_last_error(char* buffer, size_t buffer_len);
    const char* rustdesk_version();
}

static constexpr uint32_t kRustDeskStreamStatsVersion = 1;
static constexpr uint32_t kRustDeskDisplaySnapshotVersion = 1;
static constexpr uint32_t kRustDeskVideoFrameAbiVersion = 2;
static_assert(sizeof(RustDeskFfiStreamStats) == 96,
              "RustDeskStreamStats ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiStreamStats) == 8,
              "RustDeskStreamStats ABI alignment changed");
static_assert(offsetof(RustDeskFfiStreamStats, version) == 0);
static_assert(offsetof(RustDeskFfiStreamStats, state) == 4);
static_assert(offsetof(RustDeskFfiStreamStats, last_delay_ms) == 8);
static_assert(offsetof(RustDeskFfiStreamStats, target_bitrate_kbps) == 12);
static_assert(offsetof(RustDeskFfiStreamStats, video_messages) == 16);
static_assert(offsetof(RustDeskFfiStreamStats, video_frames) == 24);
static_assert(offsetof(RustDeskFfiStreamStats, keyframes) == 32);
static_assert(offsetof(RustDeskFfiStreamStats, encoded_bytes) == 40);
static_assert(offsetof(RustDeskFfiStreamStats, audio_frames) == 48);
static_assert(offsetof(RustDeskFfiStreamStats, cadence_gaps) == 56);
static_assert(offsetof(RustDeskFfiStreamStats, max_cadence_gap_ms) == 64);
static_assert(offsetof(RustDeskFfiStreamStats, test_delay_count) == 72);
static_assert(offsetof(RustDeskFfiStreamStats, actual_codec) == 80);
static_assert(offsetof(RustDeskFfiStreamStats, width) == 84);
static_assert(offsetof(RustDeskFfiStreamStats, height) == 88);
static_assert(offsetof(RustDeskFfiStreamStats, connection_path) == 92);
static_assert(sizeof(RustDeskFfiDisplaySnapshot) == 36,
              "RustDeskDisplaySnapshot ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiDisplaySnapshot) == 4,
              "RustDeskDisplaySnapshot ABI alignment changed");
static_assert(offsetof(RustDeskFfiDisplaySnapshot, version) == 0);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, currentDisplay) == 4);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, width) == 8);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, height) == 12);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, originalWidth) == 16);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, originalHeight) == 20);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, scaleMilli) == 24);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, geometryEpoch) == 28);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, resolutionCount) == 32);
static_assert(sizeof(RustDeskFfiResolution) == 8,
              "RustDeskResolution ABI size changed; update both sides together");
static_assert(sizeof(RustDeskFfiDisplayInfoSnapshot) == 176,
              "RustDeskDisplayInfoSnapshot ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiDisplayInfoSnapshot) == 4,
              "RustDeskDisplayInfoSnapshot ABI alignment changed");
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, display) == 0);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, x) == 4);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, y) == 8);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, width) == 12);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, height) == 16);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, originalWidth) == 20);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, originalHeight) == 24);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, scaleMilli) == 28);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, online) == 32);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, cursorEmbedded) == 33);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, nameLen) == 36);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, name) == 40);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, resolutionOffset) == 168);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, resolutionCount) == 172);
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
#include <cstddef>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>
#include <future>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0002
#define LOG_TAG "RUSTDESK_BRIDGE"

#define RD_DEFAULT_TCP_PORT  21116
#define RD_IPC_CONNECT_TIMEOUT 5

// 运行时 socket 路径 (可被 ArkTS setHelperSocketPath NAPI 覆盖)
static std::string g_socketPath = RD_IPC_SOCKET_PATH_DEFAULT;
const char* g_rustdeskHelperSocketPath = RD_IPC_SOCKET_PATH_DEFAULT;

// A RustDesk adapter is shared by the extension registry. Keep cursor
// generations process-wide so reconnecting the same numeric session id cannot
// make a late N-API result look current.
static std::atomic<uint64_t> g_nextRustDeskCursorGeneration {1};

// FFI callbacks are delivered with one opaque user-data pointer for the whole
// stream. Carry the generation captured when the handle was created so a
// callback from a torn-down stream cannot mutate the next session's cursor
// store after reconnecting with the same numeric session id.
struct RustDeskFfiCallbackContext {
    void* impl = nullptr;
    // The callback context is the last owner kept by the Rust stream.  A
    // shared back-reference prevents Impl destruction while a callback or a
    // deferred rustdesk_disconnect() still has the opaque user-data pointer.
    std::shared_ptr<void> implKeepAlive;
    uint64_t generation = 0;
    uint64_t ownerToken = 0;
    // Separate callback-admission epoch. A disconnect invalidates the FFI
    // callback stream even when the logical session generation is retained
    // for a subsequent reconnect.
    uint64_t admissionEpoch = 0;
};

namespace {

// rustdesk_disconnect() joins the stream producer.  Never invoke it from an
// FFI callback thread, including the callback's synchronous re-entry into
// disconnect(); doing so would make the producer join itself.  Deferred
// handles are drained by a non-callback teardown/maintenance path instead.
thread_local bool g_inRustDeskFfiCallback = false;

class RustDeskFfiCallbackScope final {
public:
    RustDeskFfiCallbackScope() : previous_(g_inRustDeskFfiCallback) {
        g_inRustDeskFfiCallback = true;
    }

    RustDeskFfiCallbackScope(const RustDeskFfiCallbackScope&) = delete;
    RustDeskFfiCallbackScope& operator=(const RustDeskFfiCallbackScope&) = delete;

    // The FFI user-data context is owned by Impl.  Counting every callback
    // lets the cleanup worker wait until a synchronous N-API re-entry has
    // returned before reclaiming that context; a completed connect thread is
    // not sufficient because the Rust streaming callbacks run on a separate
    // worker.
    void track(std::atomic<uint32_t>* active, std::mutex* mutex,
               std::condition_variable* condition) {
        if (active_ != nullptr || active == nullptr || mutex == nullptr ||
            condition == nullptr) {
            return;
        }
        active_ = active;
        mutex_ = mutex;
        condition_ = condition;
        active_->fetch_add(1, std::memory_order_acq_rel);
    }

    ~RustDeskFfiCallbackScope() {
        if (active_ != nullptr &&
            active_->fetch_sub(1, std::memory_order_acq_rel) == 1 &&
            condition_ != nullptr) {
            condition_->notify_all();
        }
        g_inRustDeskFfiCallback = previous_;
    }

private:
    bool previous_ = false;
    std::atomic<uint32_t>* active_ = nullptr;
    std::mutex* mutex_ = nullptr;
    std::condition_variable* condition_ = nullptr;
};

class RustDeskCompletionFence {
public:
    explicit RustDeskCompletionFence(bool done = false) : done_(done) {}

    bool load(std::memory_order order = std::memory_order_seq_cst) const {
        return done_.load(order);
    }

    void store(bool done, std::memory_order order = std::memory_order_seq_cst) {
        done_.store(done, order);
        if (done) condition_.notify_all();
    }

    void waitDone() const {
        std::unique_lock<std::mutex> lock(mutex_);
        condition_.wait(lock, [this]() {
            return done_.load(std::memory_order_acquire);
        });
    }

private:
    std::atomic<bool> done_ {false};
    mutable std::mutex mutex_;
    mutable std::condition_variable condition_;
};

struct DeferredRustDeskThreadJoin {
    std::thread worker;
    std::shared_ptr<void> keepAlive;
    std::function<void()> afterJoin;
    std::shared_ptr<RustDeskCompletionFence> done;
};

// A callback may synchronously call RustDeskBridge::disconnect() from the
// connect/stream thread. Keep both the thread object and Impl lifetime in a
// dedicated owner until the worker returns; never detach then reset callback
// context underneath it.
class RustDeskThreadJoiner {
public:
    RustDeskThreadJoiner() : worker_([this]() { run(); }) {}

    void enqueue(std::thread worker, std::shared_ptr<void> keepAlive,
                 std::function<void()> afterJoin,
                 std::shared_ptr<RustDeskCompletionFence> done = nullptr) {
        if (!worker.joinable()) return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) {
                // Shutdown owns the worker lifecycle. Never join an
                // arbitrary callback thread on this caller after the owner
                // has entered its bounded shutdown phase.
                pending_.push_back(DeferredRustDeskThreadJoin {
                    std::move(worker), std::move(keepAlive), std::move(afterJoin),
                    std::move(done)});
                condition_.notify_all();
                return;
            }
            pending_.push_back(DeferredRustDeskThreadJoin {
                std::move(worker), std::move(keepAlive), std::move(afterJoin),
                std::move(done)});
        }
        condition_.notify_one();
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return condition_.wait_for(lock, timeout, [this]() {
            return pending_.empty() && active_ == 0;
        });
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + active_;
    }

    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        condition_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        if (!condition_.wait_until(lock, deadline, [this]() { return workerDone_; })) {
            return false;
        }
        lock.unlock();
        if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
            worker_.join();
        }
        return true;
    }

private:
    void run() {
        for (;;) {
            DeferredRustDeskThreadJoin job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                condition_.wait(lock, [this]() {
                    return stopping_ || !pending_.empty();
                });
                if (pending_.empty() && stopping_) {
                    workerDone_ = true;
                    condition_.notify_all();
                    return;
                }
                job = std::move(pending_.front());
                pending_.pop_front();
                ++active_;
            }
            // Do not let a blocked worker at the queue head prevent completed
            // RustDesk jobs from being joined and released.
            if (job.done && !job.done->load(std::memory_order_acquire)) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_.push_back(std::move(job));
                    --active_;
                }
                condition_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            job.worker.join();
            if (job.afterJoin) job.afterJoin();
            job.keepAlive.reset();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                --active_;
                condition_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<DeferredRustDeskThreadJoin> pending_;
    std::thread worker_;
    bool stopping_ = false;
    bool workerDone_ = false;
    std::size_t active_ = 0;
};

std::mutex g_rustDeskThreadJoinerOwnerMutex;
RustDeskThreadJoiner* g_rustDeskThreadJoinerOwner = nullptr;

RustDeskThreadJoiner& rustDeskThreadJoiner() {
    std::lock_guard<std::mutex> lock(g_rustDeskThreadJoinerOwnerMutex);
    if (g_rustDeskThreadJoinerOwner == nullptr) {
        g_rustDeskThreadJoinerOwner = new RustDeskThreadJoiner();
    }
    return *g_rustDeskThreadJoinerOwner;
}

bool shutdownRustDeskThreadJoinerWithin(std::chrono::milliseconds timeout) {
    RustDeskThreadJoiner* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rustDeskThreadJoinerOwnerMutex);
        owner = g_rustDeskThreadJoinerOwner;
    }
    if (owner == nullptr) return true;
    const bool done = owner->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_rustDeskThreadJoinerOwnerMutex);
        if (g_rustDeskThreadJoinerOwner == owner) {
            g_rustDeskThreadJoinerOwner = nullptr;
            // Retain the joined retired owner until process exit. A caller
            // that obtained the raw reference before shutdown may still be
            // returning from a method after the global slot is cleared.
        }
    }
    return done;
}

struct RustDeskIpcConnectJob {
    std::atomic<bool> cancelled {false};
    std::atomic<int> fd {-1};
    RustDeskCompletionFence done;
};

struct DeferredRustDeskIpcJoin {
    std::shared_ptr<RustDeskIpcConnectJob> job;
    std::thread worker;
};

// The embedded IPC helper never detaches a connection worker.  The joiner
// owns each worker until the worker has closed its duplicated client fd; stop
// cancels active jobs before draining the queue.
class RustDeskIpcJoiner {
public:
    RustDeskIpcJoiner() : worker_([this]() { run(); }) {}

    bool enqueue(std::shared_ptr<RustDeskIpcConnectJob> job, std::thread worker) {
        if (!job || !worker.joinable()) return false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) {
                job->cancelled.store(true, std::memory_order_release);
                const int fd = job->fd.load(std::memory_order_acquire);
                if (fd >= 0) shutdown(fd, SHUT_RDWR);
                pending_.push_back(DeferredRustDeskIpcJoin {std::move(job), std::move(worker)});
                condition_.notify_all();
                return false;
            }
            pending_.push_back(DeferredRustDeskIpcJoin {std::move(job), std::move(worker)});
        }
        condition_.notify_one();
        return true;
    }

private:
    void run() {
        for (;;) {
            DeferredRustDeskIpcJoin item;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                condition_.wait(lock, [this]() { return stopping_ || !pending_.empty(); });
                if (pending_.empty() && stopping_) {
                    workerDone_ = true;
                    condition_.notify_all();
                    return;
                }
                item = std::move(pending_.front());
                pending_.pop_front();
                active_.push_back(item.job);
            }
            // Completed IPC jobs behind a blocked one must still be released.
            if (!item.job->done.load(std::memory_order_acquire)) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    active_.erase(std::remove(active_.begin(), active_.end(), item.job),
                                  active_.end());
                    pending_.push_back(std::move(item));
                }
                condition_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            item.worker.join();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                active_.erase(std::remove(active_.begin(), active_.end(), item.job),
                              active_.end());
                if (stopping_ && pending_.empty() && active_.empty()) {
                    condition_.notify_all();
                }
            }
        }
    }

    std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<DeferredRustDeskIpcJoin> pending_;
    std::vector<std::shared_ptr<RustDeskIpcConnectJob>> active_;
    bool stopping_ = false;
    bool workerDone_ = false;
    std::thread worker_;

public:
    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
            for (const auto& job : active_) {
                job->cancelled.store(true, std::memory_order_release);
                const int fd = job->fd.load(std::memory_order_acquire);
                if (fd >= 0) shutdown(fd, SHUT_RDWR);
            }
        }
        condition_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        if (!condition_.wait_until(lock, deadline, [this]() { return workerDone_; })) {
            return false;
        }
        lock.unlock();
        if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
            worker_.join();
        }
        return true;
    }
};

std::mutex g_rustDeskIpcJoinerOwnerMutex;
RustDeskIpcJoiner* g_rustDeskIpcJoinerOwner = nullptr;

RustDeskIpcJoiner& rustDeskIpcJoiner() {
    std::lock_guard<std::mutex> lock(g_rustDeskIpcJoinerOwnerMutex);
    if (g_rustDeskIpcJoinerOwner == nullptr) {
        g_rustDeskIpcJoinerOwner = new RustDeskIpcJoiner();
    }
    return *g_rustDeskIpcJoinerOwner;
}

bool shutdownRustDeskIpcJoinerWithin(std::chrono::milliseconds timeout) {
    RustDeskIpcJoiner* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rustDeskIpcJoinerOwnerMutex);
        owner = g_rustDeskIpcJoinerOwner;
    }
    if (owner == nullptr) return true;
    const bool done = owner->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_rustDeskIpcJoinerOwnerMutex);
        if (g_rustDeskIpcJoinerOwner == owner) {
            g_rustDeskIpcJoinerOwner = nullptr;
            // The worker has joined, but an earlier caller may still hold the
            // raw owner reference. Retire without delete to close the TOCTOU
            // window; a later call creates a new owner.
        }
    }
    return done;
}

} // namespace

// ============================================================
// RustDesk 真实 TCP 连接 (在独立线程中运行)
// ============================================================
static void rdRealConnectThread(RdIpcConnectReq req,
                                const std::shared_ptr<RustDeskIpcConnectJob>& job) {
    struct IpcDoneFence {
        std::shared_ptr<RustDeskIpcConnectJob> job;
        ~IpcDoneFence() {
            if (job) {
                job->done.store(true, std::memory_order_release);
            }
        }
    } done {job};
    const int ipcClientFd = job ? job->fd.load(std::memory_order_acquire) : -1;
    if (!job || ipcClientFd < 0) return;
    const auto closeJobFd = [&]() {
        const int fd = job->fd.exchange(-1, std::memory_order_acq_rel);
        if (fd >= 0) {
            close(fd);
        }
    };
    if (job->cancelled.load(std::memory_order_acquire)) {
        closeJobFd();
        return;
    }
    const std::string endpointId = SafeLog::HashForLog(req.host);
    const std::string peerId = SafeLog::HashForLog(req.peerId);
    OH_LOG_INFO(LOG_APP,
                "[RustDesk-REAL] 开始连接 endpointId=%{public}s port=%{public}u peerId=%{public}s",
                endpointId.c_str(), req.port, peerId.c_str());

    int tcpFd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcpFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-REAL] socket 失败: %{public}s", strerror(errno));
        // 发送错误 ACK
        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x01};
        send(ipcClientFd, errAck, 6, 0);
        closeJobFd();
        return;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(req.port));
    if (inet_pton(AF_INET, req.host, &addr.sin_addr) <= 0) {
        OH_LOG_ERROR(LOG_APP,
                     "[RustDesk-REAL] 地址解析失败 endpointId=%{public}s",
                     endpointId.c_str());
        close(tcpFd);
        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x02};
        send(ipcClientFd, errAck, 6, 0);
        closeJobFd();
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
        closeJobFd();
        return;
    }
    if (job->cancelled.load(std::memory_order_acquire)) {
        close(tcpFd);
        closeJobFd();
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
    close(tcpFd);
    closeJobFd();
}

void rdSetHelperSocketPath(const char* path) {
    if (path && path[0] != '\0') {
        g_socketPath = path;
        g_rustdeskHelperSocketPath = g_socketPath.c_str();
        OH_LOG_INFO(LOG_APP,
                    "[RustDesk-IPC] socket 路径已更新 pathId=%{public}s",
                    SafeLog::HashForLog(g_rustdeskHelperSocketPath).c_str());
    }
}

// helper 二进制路径 (由 ArkTS setHelperSocketPath 同一调用设置)
static std::string g_helperBinPath;

void rdSetHelperBinPath(const char* path) {
    if (path && path[0] != '\0') {
        g_helperBinPath = path;
        OH_LOG_INFO(LOG_APP,
                    "[RustDesk-IPC] helper 路径已设置 pathId=%{public}s",
                    SafeLog::HashForLog(path).c_str());
    }
}

// ============================================================
// 内置 IPC 服务端 (替代独立 helper 进程)
// 运行在 pthread 中, 省去 dlopen/SELinux/namespace 问题
// ============================================================
static std::atomic<bool> g_helperRunning {false};
static std::mutex g_helperClientsMutex;
static std::set<int> g_helperClientFds;
static void* rdHelperThreadFn(void* arg);

class RustDeskIpcHelperOwner {
public:
    bool start(const std::string& socketPath) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (thread_.joinable() && helperDone_->load(std::memory_order_acquire)) {
            thread_.join();
        }
        if (thread_.joinable() || g_helperRunning.load(std::memory_order_acquire)) {
            return true;
        }
        auto* pathCopy = strdup(socketPath.c_str());
        if (!pathCopy) return false;
        helperDone_ = std::make_shared<std::atomic<bool>>(false);
        auto done = helperDone_;
        try {
            thread_ = std::thread([this, done, pathCopy]() {
                rdHelperThreadFn(pathCopy);
                done->store(true, std::memory_order_release);
                doneCv_.notify_all();
            });
        } catch (...) {
            free(pathCopy);
            helperDone_->store(true, std::memory_order_release);
            return false;
        }
        return true;
    }

    void stop() {
        (void)stopWithin(std::chrono::milliseconds(500));
    }

    bool stopWithin(std::chrono::milliseconds timeout) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            g_helperRunning.store(false, std::memory_order_release);
        }
        // Wake accept() and any client recv() without relying on a detached
        // pthread eventually noticing a flag.
        int wakeFd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (wakeFd >= 0) {
            struct sockaddr_un addr {};
            addr.sun_family = AF_UNIX;
            strncpy(addr.sun_path, g_socketPath.c_str(), sizeof(addr.sun_path) - 1);
            (void)connect(wakeFd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr));
            close(wakeFd);
        }
        {
            std::lock_guard<std::mutex> lock(g_helperClientsMutex);
            for (const int fd : g_helperClientFds) {
                shutdown(fd, SHUT_RDWR);
            }
        }
        if (!thread_.joinable()) {
            return true;
        }
        if (thread_.get_id() == std::this_thread::get_id()) {
            return false;
        }
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        std::unique_lock<std::mutex> doneLock(doneMutex_);
        if (!doneCv_.wait_until(doneLock, deadline, [this]() {
                return helperDone_->load(std::memory_order_acquire);
            })) {
            return false;
        }
        doneLock.unlock();
        thread_.join();
        return true;
    }

    std::mutex mutex_;
    std::mutex doneMutex_;
    std::condition_variable doneCv_;
    std::thread thread_;
    std::shared_ptr<std::atomic<bool>> helperDone_ =
        std::make_shared<std::atomic<bool>>(true);
};

std::mutex g_rustDeskIpcHelperOwnerMutex;
RustDeskIpcHelperOwner* g_rustDeskIpcHelperOwner = nullptr;

RustDeskIpcHelperOwner& rustDeskIpcHelperOwner() {
    std::lock_guard<std::mutex> lock(g_rustDeskIpcHelperOwnerMutex);
    if (g_rustDeskIpcHelperOwner == nullptr) {
        g_rustDeskIpcHelperOwner = new RustDeskIpcHelperOwner();
    }
    return *g_rustDeskIpcHelperOwner;
}

bool shutdownRustDeskIpcHelperOwnerWithin(std::chrono::milliseconds timeout) {
    RustDeskIpcHelperOwner* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rustDeskIpcHelperOwnerMutex);
        owner = g_rustDeskIpcHelperOwner;
    }
    if (owner == nullptr) {
        return true;
    }
    const bool done = owner->stopWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_rustDeskIpcHelperOwnerMutex);
        if (g_rustDeskIpcHelperOwner == owner) {
            g_rustDeskIpcHelperOwner = nullptr;
            // Retain the joined retired helper until process exit. A caller
            // may still be returning through a raw owner reference obtained
            // before the shutdown lookup lock was released.
        }
    }
    return done;
}

static void* rdHelperThreadFn(void* arg) {
    const char* rawSocketPath = (const char*)arg;
    const std::string socketPath = rawSocketPath ? rawSocketPath : "";
    free(arg);
    if (socketPath.empty()) return nullptr;
    OH_LOG_INFO(LOG_APP,
                "[RustDesk-IPC] helper 线程启动 socketPathId=%{public}s",
                SafeLog::HashForLog(socketPath).c_str());

    // 删掉旧 socket 文件
    unlink(socketPath.c_str());

    int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper socket() 失败: %{public}s", strerror(errno));
        g_helperRunning.store(false, std::memory_order_release);
        return nullptr;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);

    if (bind(listenFd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper bind() 失败: %{public}s", strerror(errno));
        close(listenFd);
        g_helperRunning.store(false, std::memory_order_release);
        return nullptr;
    }

    if (listen(listenFd, 1) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper listen() 失败: %{public}s", strerror(errno));
        close(listenFd);
        g_helperRunning.store(false, std::memory_order_release);
        return nullptr;
    }

    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 监听中...");
    g_helperRunning.store(true, std::memory_order_release);

    while (g_helperRunning.load(std::memory_order_acquire)) {
        int clientFd = accept(listenFd, nullptr, nullptr);
        if (clientFd < 0) {
            if (errno == EINTR) { continue; }
            break;
        }
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 客户端已连接 fd=%{public}d", clientFd);
        {
            std::lock_guard<std::mutex> lock(g_helperClientsMutex);
            g_helperClientFds.insert(clientFd);
        }

        // 简单帧循环: 读 5 字节头 → 读 payload → 处理
        uint8_t header[5];
        std::vector<uint8_t> payload;
        while (g_helperRunning.load(std::memory_order_acquire)) {
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
                        // Duplicate the client fd so helper teardown cannot
                        // close/reuse the descriptor while the real connect
                        // worker is still sending its ACK. The join owner
                        // drains this worker; there is no detached path.
                        const int workerFd = dup(clientFd);
                        if (workerFd < 0) {
                            uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0xFE};
                            send(clientFd, errAck, 6, 0);
                            break;
                        }
                        auto job = std::make_shared<RustDeskIpcConnectJob>();
                        job->fd.store(workerFd, std::memory_order_release);
                        std::thread realConn;
                        try {
                            realConn = std::thread(rdRealConnectThread, req, job);
                        } catch (const std::exception& ex) {
                            job->cancelled.store(true, std::memory_order_release);
                            shutdown(workerFd, SHUT_RDWR);
                            close(workerFd);
                            job->fd.store(-1, std::memory_order_release);
                            uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0xFD};
                            send(clientFd, errAck, 6, 0);
                            OH_LOG_ERROR(LOG_APP,
                                "[RustDesk-IPC] connect worker start failed: %{public}s",
                                ex.what());
                            break;
                        } catch (...) {
                            job->cancelled.store(true, std::memory_order_release);
                            shutdown(workerFd, SHUT_RDWR);
                            close(workerFd);
                            job->fd.store(-1, std::memory_order_release);
                            uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0xFD};
                            send(clientFd, errAck, 6, 0);
                            OH_LOG_ERROR(LOG_APP,
                                "[RustDesk-IPC] connect worker start failed");
                            break;
                        }
                        if (!rustDeskIpcJoiner().enqueue(job, std::move(realConn))) {
                            job->cancelled.store(true, std::memory_order_release);
                            shutdown(workerFd, SHUT_RDWR);
                            close(workerFd);
                            job->fd.store(-1, std::memory_order_release);
                        }
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
        {
            std::lock_guard<std::mutex> lock(g_helperClientsMutex);
            g_helperClientFds.erase(clientFd);
        }
        close(clientFd);
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 客户端断开");
    }

    close(listenFd);
    unlink(socketPath.c_str());
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 线程退出");
    g_helperRunning.store(false, std::memory_order_release);
    return nullptr;
}

static bool rdTryStartHelper() {
    if (g_helperRunning.load(std::memory_order_acquire)) {
        return true;
    }
    if (!rustDeskIpcHelperOwner().start(g_socketPath)) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper thread start failed");
        return false;
    }
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
    RustDeskDisplayStateCallback displayStateCallback;
    RustDeskDisplayControlPlane displayControl;
    std::mutex              mutex;
    std::atomic<uint64_t>   connectSerial {0};
    std::atomic<bool>       disconnectRequested {false};
    std::atomic<bool>       ffiStreamEnded {false};
    std::atomic<bool>       inputForwardReady {false};
    std::atomic<uint64_t>   sessionId {0};
    std::atomic<uint64_t>   cursorGeneration {0};
    std::atomic<uint64_t>   ownerToken {0};
    std::atomic<uint64_t>   ffiAdmissionEpoch {1};
    // Serializes callback admission with explicit teardown. It is held only
    // while checking/committing local state, never across an external sink.
    std::mutex              continuityAdmissionMutex;
    std::shared_ptr<RustDeskConnectionContinuityExecutor> continuityExecutor =
        std::make_shared<RustDeskConnectionContinuityExecutor>();
    RustDeskContinuityQuiesceState continuityQuiesce;
    std::mutex continuityOwnerTransitionMutex;
    Render::DecoderSessionIdentity pendingContinuityOwner;
    RustDeskBridge::ContinuityGenerationCallback continuityGenerationCallback;
    std::atomic<bool> continuityReconnectPending {false};
    std::atomic<bool> continuityAttemptActive {false};
    std::atomic<uint64_t> continuityAttemptToken {0};
    std::atomic<uint64_t> nextContinuityAttemptToken {1};
    std::atomic<uint32_t> continuityConnectCallCount {0};
    // A prepared continuity attempt becomes irrevocable only at the network
    // call claim. Disconnect orders against this state under the same
    // admission mutex, but the external FFI call itself remains lock-free.
    std::atomic<uint64_t> continuityNetworkClaimToken {0};
    std::atomic<bool> continuityNetworkCallActive {false};
    std::atomic<bool> continuityNetworkCallCancelled {false};
    std::atomic<bool> awaitingFirstGenerationFrame {false};
    std::atomic<uint64_t> nextFirstFrameClaimToken {1};
    std::atomic<uint64_t> firstFrameClaimToken {0};
    // Set while continuityAdmissionMutex is held. This is the commit side
    // of the first-frame claim: disconnect and frame commit therefore have a
    // single total order instead of a check-then-act gap after the lock is
    // released.
    std::atomic<uint64_t> firstFrameCommittedToken {0};
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void()> firstFrameClaimHook;
    std::function<void(int)> continuityAttemptStageHook;
    std::function<int(uint64_t, uint64_t)> continuityConnectResultHook;
#endif
    std::atomic<uint64_t>   callbackVideoFrames {0};
    std::atomic<uint64_t>   callbackVideoBytes {0};
    std::atomic<uint64_t>   callbackKeyframes {0};
    std::atomic<uint64_t>   callbackAudioFrames {0};
    std::atomic<uint64_t>   callbackCursorShape {0};
    std::atomic<uint64_t>   callbackCursorPosition {0};
    std::atomic<uint64_t>   callbackCursorVisibility {0};
    std::atomic<uint64_t>   callbackCursorCacheMiss {0};
    std::atomic<int>        callbackCodec {-1};
    std::atomic<int>        callbackWidth {0};
    std::atomic<int>        callbackHeight {0};
    std::atomic<uint64_t>   lastFrameAtMs {0};
    std::mutex              cadenceMutex;
    bool                    cadenceInitialized = false;
    std::chrono::steady_clock::time_point cadenceLastFrameAt {};
    std::chrono::steady_clock::time_point cadenceWindowStartedAt {};
    uint64_t                cadenceWindowFrames = 0;
    uint64_t                cadenceWindowMaxGapMs = 0;
    uint64_t                cadenceGapCount = 0;
    RemoteCursorStore       cursorStore;
    int                     ipcFd = -1;   // IPC socket fd (IPC 模式)
    int                     sockFd = -1;  // TCP socket fd (实验模式)
#ifdef RUSTDESK_USE_REAL_CORE
    std::unique_ptr<RustDeskFfiCallbackContext> ffiCallbackContext;
    // FFI callbacks can synchronously re-enter NAPI and disconnect while the
    // Rust connect worker has already returned its opaque handle.  Keep the
    // callback context alive until every callback has left, independently of
    // the connect-thread completion fence.
    std::atomic<uint32_t> ffiCallbackActive {0};
    std::mutex ffiCallbackMutex;
    std::condition_variable ffiCallbackCv;
    std::atomic<uint64_t> ffiHandleGeneration {0};
    // FFI connect() 在后台执行，但不能 detach：断开时必须等待它结束，
    // 否则旧连接可能在下一次连接已经开始后仍持有 rendezvous/relay 资源。
    std::thread              ffiConnectThread;
    std::shared_ptr<RustDeskCompletionFence> ffiConnectDone;
    // 流线程通过 onFfiDisconnect 回调结束时，不能从自身 join；把延迟释放
    // 的线程保留下来，由 disconnect() 统一 join，避免释放任务悬空。
    std::vector<std::thread> ffiCleanupThreads;
    std::vector<std::shared_ptr<RustDeskCompletionFence>> ffiCleanupDone;
    // If a callback-return fence exceeds the cleanup worker's bounded wait,
    // retain the detached handle together with the fence. The next callback
    // return or disconnect drain can then reclaim it without touching a live
    // callback-owned stream.
    std::vector<std::pair<void*, std::shared_future<void>>> ffiDeferredHandleFences;
    std::atomic<uint32_t> ffiDeferredJoinCount {0};
#endif
    // Potentially blocking audio/FFI quiesce work is handed off here. The
    // bridge owns this thread and moves it to the deferred joiner during
    // disconnect; it is never detached.
    std::thread continuityQuiesceThread;
    std::shared_ptr<RustDeskCompletionFence> continuityQuiesceDoneFence =
        std::make_shared<RustDeskCompletionFence>(true);
    std::atomic<bool> continuityQuiesceActive {false};
    std::atomic<bool> continuityQuiesceDone {false};

    void setState(ConnectionState s, const std::string& msg = "") {
        ConnectionStateCallback cb;
        {
            std::lock_guard<std::mutex> lock(mutex);
            state = s;
            cb = stateCallback;
        }
        if (cb) { cb(s, msg); }
    }

    ~Impl() {
        if (continuityExecutor) {
            continuityExecutor->setCallbacks({});
            continuityExecutor->shutdown();
            (void)RustDeskConnectionContinuityExecutor::shutdownDeferredWithin(
                std::chrono::milliseconds(500));
        }
    }
};

static uint64_t rdSteadyNowMs() {
    using Clock = std::chrono::steady_clock;
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        Clock::now().time_since_epoch()).count());
}

#ifdef RUSTDESK_USE_REAL_CORE
void RustDeskBridge::drainDeferredFfiHandles(RustDeskBridge::Impl* impl) {
    if (!impl || g_inRustDeskFfiCallback) {
        return;
    }
    std::vector<void*> readyHandles;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        auto it = impl->ffiDeferredHandleFences.begin();
        while (it != impl->ffiDeferredHandleFences.end()) {
            if (it->second.wait_for(std::chrono::milliseconds(0)) ==
                std::future_status::ready) {
                readyHandles.push_back(it->first);
                it = impl->ffiDeferredHandleFences.erase(it);
            } else {
                ++it;
            }
        }
    }
    for (void* handle : readyHandles) {
        if (handle) {
            rustdesk_disconnect(handle);
        }
    }
}

void RustDeskBridge::waitForFfiCallbacks(RustDeskBridge::Impl* impl) {
    if (!impl) {
        return;
    }
    std::unique_lock<std::mutex> lock(impl->ffiCallbackMutex);
    impl->ffiCallbackCv.wait(lock, [impl]() {
        return impl->ffiCallbackActive.load(std::memory_order_acquire) == 0;
    });
}

void RustDeskBridge::retainDeferredFfiHandleForMaintenance(
    const std::shared_ptr<RustDeskBridge::Impl>& keepAlive, void* handle) {
    if (!keepAlive || handle == nullptr) {
        return;
    }
    try {
        // A ready fence makes the handle eligible on the next non-callback
        // maintenance pass.  In particular, do not call rustdesk_disconnect
        // inline when the cleanup worker could not be created: this function
        // is also reached from onFfiDisconnect, and Rust's destructor joins
        // the stream producer.
        std::promise<void> promise;
        promise.set_value();
        const std::shared_future<void> ready = promise.get_future().share();
        std::lock_guard<std::mutex> lock(keepAlive->mutex);
        keepAlive->ffiDeferredHandleFences.emplace_back(handle, ready);
    } catch (...) {
        // There is no safe synchronous fallback from an FFI callback.  Keep
        // the process alive and report the leak explicitly; a later process
        // teardown will reclaim the Rust client if the allocator recovers.
        OH_LOG_ERROR(LOG_APP,
            "[RustDesk-FFI] deferred handle retention failed; refusing callback-thread disconnect handle=%{public}p",
            handle);
    }
}

void RustDeskBridge::scheduleFfiHandleCleanup(
    const std::shared_ptr<RustDeskBridge::Impl>& keepAlive, void* handle) {
    if (!keepAlive || handle == nullptr) {
        return;
    }

    // Never reclaim a Rust client from the transport callback itself.  The
    // Rust API has a deferred join owner, but the C++ callback context also
    // needs an explicit fence: rustdesk_connect_v4() may have returned while
    // the streaming callback is still executing.
    auto done = std::make_shared<RustDeskCompletionFence>(false);
    auto cleanup = [keepAlive, handle, done]() {
        rustdesk_disconnect(handle);
        RustDeskBridge::waitForFfiCallbacks(keepAlive.get());
        done->store(true, std::memory_order_release);
    };

    std::thread worker;
    try {
        worker = std::thread(std::move(cleanup));
    } catch (const std::exception& ex) {
        OH_LOG_ERROR(LOG_APP,
            "[RustDesk-FFI] cleanup worker start failed: %{public}s", ex.what());
        retainDeferredFfiHandleForMaintenance(keepAlive, handle);
        return;
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-FFI] cleanup worker start failed");
        retainDeferredFfiHandleForMaintenance(keepAlive, handle);
        return;
    }

    try {
        std::lock_guard<std::mutex> lock(keepAlive->mutex);
        keepAlive->ffiCleanupDone.push_back(done);
        keepAlive->ffiCleanupThreads.push_back(std::move(worker));
    } catch (const std::exception& ex) {
        OH_LOG_ERROR(LOG_APP,
            "[RustDesk-FFI] cleanup worker publication failed: %{public}s", ex.what());
        if (worker.joinable()) {
            rustDeskThreadJoiner().enqueue(
                std::move(worker), keepAlive,
                [keepAlive]() {
                    std::lock_guard<std::mutex> lock(keepAlive->mutex);
                    keepAlive->ffiCallbackContext.reset();
                    keepAlive->continuityQuiesce.markDeferredDestroyComplete();
                }, done);
        }
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-FFI] cleanup worker publication failed");
        if (worker.joinable()) {
            rustDeskThreadJoiner().enqueue(
                std::move(worker), keepAlive,
                [keepAlive]() {
                    std::lock_guard<std::mutex> lock(keepAlive->mutex);
                    keepAlive->ffiCallbackContext.reset();
                    keepAlive->continuityQuiesce.markDeferredDestroyComplete();
                }, done);
        }
    }
}

void RustDeskBridge::harvestCompletedFfiWorkers(RustDeskBridge::Impl* impl) {
    if (!impl) {
        return;
    }
    std::vector<std::pair<std::thread, std::shared_ptr<RustDeskCompletionFence>>> ready;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        if (impl->ffiConnectThread.joinable() && impl->ffiConnectDone &&
            impl->ffiConnectDone->load(std::memory_order_acquire)) {
            ready.emplace_back(std::move(impl->ffiConnectThread),
                               std::move(impl->ffiConnectDone));
        }
        size_t index = 0;
        while (index < impl->ffiCleanupThreads.size()) {
            const auto done = index < impl->ffiCleanupDone.size()
                ? impl->ffiCleanupDone[index] : nullptr;
            if (!done || !done->load(std::memory_order_acquire)) {
                ++index;
                continue;
            }
            ready.emplace_back(std::move(impl->ffiCleanupThreads[index]), done);
            impl->ffiCleanupThreads.erase(impl->ffiCleanupThreads.begin() + index);
            if (index < impl->ffiCleanupDone.size()) {
                impl->ffiCleanupDone.erase(impl->ffiCleanupDone.begin() + index);
            }
        }
    }
    for (auto& item : ready) {
        if (item.first.joinable() &&
            item.first.get_id() != std::this_thread::get_id()) {
            item.first.join();
        }
    }

    const bool noHandle = !impl->displayControl.hasHandle();
    const bool noConnectThread = [&]() {
        std::lock_guard<std::mutex> lock(impl->mutex);
        return !impl->ffiConnectThread.joinable();
    }();
    const bool noCleanupThreads = [&]() {
        std::lock_guard<std::mutex> lock(impl->mutex);
        return impl->ffiCleanupThreads.empty();
    }();
    if (noHandle && noConnectThread && noCleanupThreads &&
        impl->ffiCallbackActive.load(std::memory_order_acquire) == 0 &&
        impl->ffiDeferredJoinCount.load(std::memory_order_acquire) == 0) {
        std::lock_guard<std::mutex> lock(impl->mutex);
        impl->ffiCallbackContext.reset();
        impl->ffiHandleGeneration.store(0, std::memory_order_release);
        impl->continuityQuiesce.markDeferredDestroyComplete();
    }
}
#endif

#ifdef RUSTDESK_USE_REAL_CORE
struct RustDeskFfiVideoFrameV1 {
    const uint8_t* data;
    size_t         size;
    int            width;
    int            height;
    int            codec;
    uint64_t       timestamp;
    bool           isKeyFrame;
};

struct RustDeskFfiVideoFrameV2 {
    const uint8_t* data;
    size_t         size;
    int            width;
    int            height;
    int            codec;
    uint64_t       timestamp;
    bool           isKeyFrame;
    int            display;
    uint32_t       abiVersion;
    uint32_t       structSize;
};

static_assert(sizeof(RustDeskFfiVideoFrameV1) == 48,
              "RustDesk V1 video frame ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiVideoFrameV1) == 8,
              "RustDesk V1 video frame ABI alignment changed");
static_assert(offsetof(RustDeskFfiVideoFrameV1, data) == 0);
static_assert(offsetof(RustDeskFfiVideoFrameV1, size) == 8);
static_assert(offsetof(RustDeskFfiVideoFrameV1, width) == 16);
static_assert(offsetof(RustDeskFfiVideoFrameV1, height) == 20);
static_assert(offsetof(RustDeskFfiVideoFrameV1, codec) == 24);
static_assert(offsetof(RustDeskFfiVideoFrameV1, timestamp) == 32);
static_assert(offsetof(RustDeskFfiVideoFrameV1, isKeyFrame) == 40);
static_assert(sizeof(RustDeskFfiVideoFrameV2) == 56,
              "RustDesk V2 video frame ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiVideoFrameV2) == 8,
              "RustDesk V2 video frame ABI alignment changed");
static_assert(offsetof(RustDeskFfiVideoFrameV2, data) == 0);
static_assert(offsetof(RustDeskFfiVideoFrameV2, size) == 8);
static_assert(offsetof(RustDeskFfiVideoFrameV2, width) == 16);
static_assert(offsetof(RustDeskFfiVideoFrameV2, height) == 20);
static_assert(offsetof(RustDeskFfiVideoFrameV2, codec) == 24);
static_assert(offsetof(RustDeskFfiVideoFrameV2, timestamp) == 32);
static_assert(offsetof(RustDeskFfiVideoFrameV2, isKeyFrame) == 40);
static_assert(offsetof(RustDeskFfiVideoFrameV2, display) == 44);
static_assert(offsetof(RustDeskFfiVideoFrameV2, abiVersion) == 48);
static_assert(offsetof(RustDeskFfiVideoFrameV2, structSize) == 52);

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

static std::atomic<uint64_t> g_ffiMouseSendCount {0};
static std::atomic<uint64_t> g_ffiKeySendCount {0};
static std::atomic<uint64_t> g_ffiWheelSendCount {0};
static std::atomic<uint64_t> g_ffiTextSendCount {0};
static std::atomic<uint64_t> g_ffiFileSendCount {0};

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

template<typename ImplType>
static bool IsRustDeskCallbackOwnerActive(
    const ImplType* impl,
    const RustDeskFfiCallbackContext* context) {
    if (impl == nullptr || context == nullptr || context->generation == 0 ||
        context->ownerToken == 0) {
        return false;
    }
    const Render::DecoderSessionIdentity owner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    return Render::SharedSessionSinkOwnerLease().accepts(owner);
}

void RustDeskBridge::onFfiFrame(const void* framePtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* ffiFrame = static_cast<const RustDeskFfiVideoFrameV2*>(framePtr);
    if (!context || !impl || !ffiFrame || !ffiFrame->data || ffiFrame->size == 0) {
        return;
    }
    const Render::DecoderSessionIdentity callbackOwner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    // Admission is serialized only for the local check. The owner lease is
    // intentionally kept through the sink callback, so teardown can mark the
    // stream stale before waiting for this in-flight callback to drain.
    std::unique_lock<std::mutex> admissionLock(impl->continuityAdmissionMutex);
    if (context->generation == 0 ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !impl->continuityQuiesce.decoderAllowed()) {
        return;
    }
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(callbackOwner);
    if (!sinkLease) {
        return;
    }
    admissionLock.unlock();
    if (ffiFrame->abiVersion < kRustDeskVideoFrameAbiVersion ||
        ffiFrame->structSize < sizeof(RustDeskFfiVideoFrameV2)) {
        OH_LOG_WARN(LOG_APP,
            "[RustDesk-FFI] reject unsupported V2 frame abi=%{public}u size=%{public}u",
            ffiFrame->abiVersion,
            ffiFrame->structSize);
        return;
    }

    // dispatchFrame uses a short coordinator lease to observe the gate and
    // rechecks identity before crossing the external callback boundary.
    // beginDisplaySwitch() keeps only the opaque handle pinned through FFI;
    // neither path holds the non-reentrant display lease in user/Rust code.
    impl->displayControl.dispatchFrame(
        ffiFrame->display,
        ffiFrame->isKeyFrame,
        [&]() {
            return context->generation ==
                    impl->cursorGeneration.load(std::memory_order_acquire) &&
                context->ownerToken != 0 &&
                context->ownerToken == impl->ownerToken.load(std::memory_order_acquire) &&
                context->admissionEpoch == impl->ffiAdmissionEpoch.load(std::memory_order_acquire) &&
                !impl->disconnectRequested.load(std::memory_order_acquire) &&
                !impl->ffiStreamEnded.load(std::memory_order_acquire) &&
                IsRustDeskCallbackOwnerActive(impl, context);
        },
        [&](const RustDeskDisplaySwitchGateDecision& displayDecision) {
    RustDeskDisplayStateCallback displayCallback;
    if (displayDecision.publishDisplay) {
        std::lock_guard<std::mutex> lock(impl->mutex);
        displayCallback = impl->displayStateCallback;
    }
    if (displayCallback) {
        // Publish the selected display before forwarding its keyframe so the
        // decoder accepts the same frame that releases the input barrier.
        displayCallback(displayDecision.display);
    }

    uint64_t index = impl->callbackVideoFrames.fetch_add(1, std::memory_order_relaxed) + 1;
    impl->callbackVideoBytes.fetch_add(static_cast<uint64_t>(ffiFrame->size), std::memory_order_relaxed);
    if (ffiFrame->isKeyFrame) {
        impl->callbackKeyframes.fetch_add(1, std::memory_order_relaxed);
    }
    impl->callbackCodec.store(ffiFrame->codec, std::memory_order_relaxed);
    impl->callbackWidth.store(ffiFrame->width, std::memory_order_relaxed);
    impl->callbackHeight.store(ffiFrame->height, std::memory_order_relaxed);
    impl->lastFrameAtMs.store(rdSteadyNowMs(), std::memory_order_release);
    {
        using Clock = std::chrono::steady_clock;
        const auto now = Clock::now();
        std::lock_guard<std::mutex> cadenceLock(impl->cadenceMutex);
        if (!impl->cadenceInitialized) {
            impl->cadenceInitialized = true;
            impl->cadenceLastFrameAt = now;
            impl->cadenceWindowStartedAt = now;
        } else {
            const auto gapMs = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    now - impl->cadenceLastFrameAt).count());
            if (gapMs > impl->cadenceWindowMaxGapMs) {
                impl->cadenceWindowMaxGapMs = gapMs;
            }
            if (gapMs > 200) {
                impl->cadenceGapCount++;
                if (impl->cadenceGapCount <= 8 || impl->cadenceGapCount % 30 == 0) {
                    OH_LOG_WARN(LOG_APP,
                        "[RustDesk-FFI] ffi video cadence gap=%{public}llu total=%{public}llu window=%{public}llu codec=%{public}s pts=%{public}llu",
                        static_cast<unsigned long long>(gapMs),
                        static_cast<unsigned long long>(index),
                        static_cast<unsigned long long>(impl->cadenceWindowFrames),
                        rdCodecName(ffiFrame->codec),
                        static_cast<unsigned long long>(ffiFrame->timestamp));
                }
            }
            impl->cadenceLastFrameAt = now;
        }
        impl->cadenceWindowFrames++;
        const auto windowMs = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                now - impl->cadenceWindowStartedAt).count());
        if (windowMs >= 1000) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] ffi video window frames=%{public}llu total=%{public}llu max_gap=%{public}llu codec=%{public}s size=%{public}dx%{public}d",
                static_cast<unsigned long long>(impl->cadenceWindowFrames),
                static_cast<unsigned long long>(index),
                static_cast<unsigned long long>(impl->cadenceWindowMaxGapMs),
                rdCodecName(ffiFrame->codec),
                ffiFrame->width,
                ffiFrame->height);
            impl->cadenceWindowStartedAt = now;
            impl->cadenceWindowFrames = 0;
            impl->cadenceWindowMaxGapMs = 0;
        }
    }
    VideoFrameCallback cb;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        cb = impl->videoCallback;
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
            cb ? "yes" : "no");
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
        frame.display = ffiFrame->display;
        cb(frame);
    }
        });
    // Do not open the new generation before the display/sink dispatch has
    // completed. Teardown takes the admission mutex, invalidates the epoch,
    // and therefore wins deterministically if it was interleaved at the
    // first-frame barrier.
    uint64_t firstFrameClaimToken = 0;
    std::function<void()> firstFrameClaimHook;
    {
        std::lock_guard<std::mutex> lock(impl->continuityAdmissionMutex);
        bool expectedFirstFrame = true;
        const bool claimed =
            context->generation == impl->cursorGeneration.load(std::memory_order_acquire) &&
            context->ownerToken == impl->ownerToken.load(std::memory_order_acquire) &&
            context->admissionEpoch == impl->ffiAdmissionEpoch.load(std::memory_order_acquire) &&
            !impl->disconnectRequested.load(std::memory_order_acquire) &&
            !impl->ffiStreamEnded.load(std::memory_order_acquire) &&
            impl->awaitingFirstGenerationFrame.compare_exchange_strong(
                expectedFirstFrame, false, std::memory_order_acq_rel);
        if (claimed) {
            firstFrameClaimToken = impl->nextFirstFrameClaimToken.fetch_add(
                1, std::memory_order_relaxed);
            impl->firstFrameClaimToken.store(firstFrameClaimToken,
                                             std::memory_order_release);
            // Claim and commit are one admission-locked transition. The
            // callback is dispatched only after this marker is visible, so a
            // concurrent disconnect either wins before this point or is
            // ordered after the first-frame commit.
            impl->firstFrameCommittedToken.store(firstFrameClaimToken,
                                                 std::memory_order_release);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
            firstFrameClaimHook = impl->firstFrameClaimHook;
#endif
        }
    }
    if (firstFrameClaimHook) {
        // The hook is a test-only barrier after the production atomic commit
        // and outside all admission/display locks. It permits deterministic
        // disconnect-first ordering without changing callback semantics.
        firstFrameClaimHook();
    }
    // Release the callback's shared sink lease before attempting the deferred
    // owner transition. This keeps the fast-quiesce path non-blocking while
    // still closing the owner as soon as the admitted old callback drains.
    sinkLease.release();
    if (firstFrameClaimToken != 0) {
        const uint64_t frameGeneration = context->generation;
        const uint64_t frameOwnerToken = context->ownerToken;
        const uint64_t frameAdmissionEpoch = context->admissionEpoch;
        RustDeskConnectionContinuityExecutor::ActionAdmission frameAdmission =
            [impl, frameGeneration, frameOwnerToken, frameAdmissionEpoch,
             firstFrameClaimToken]() {
                return impl->cursorGeneration.load(std::memory_order_acquire) ==
                        frameGeneration &&
                    impl->ownerToken.load(std::memory_order_acquire) == frameOwnerToken &&
                    impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ==
                        frameAdmissionEpoch &&
                    impl->firstFrameClaimToken.load(std::memory_order_acquire) ==
                        firstFrameClaimToken &&
                    impl->firstFrameCommittedToken.load(std::memory_order_acquire) ==
                        firstFrameClaimToken &&
                    !impl->disconnectRequested.load(std::memory_order_acquire) &&
                    !impl->ffiStreamEnded.load(std::memory_order_acquire);
            };
        impl->continuityExecutor->firstGenerationFrameArrived(
            std::move(frameAdmission));
    }
    RustDeskBridge::completeContinuityOwnerQuiesce(impl);
}

void RustDeskBridge::onFfiAudio(const void* audioPtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* ffiAudio = static_cast<const RustDeskFfiAudioData*>(audioPtr);
    if (!impl) {
        return;
    }
    if (!context || !impl ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !impl->continuityQuiesce.audioAllowed() ||
        !ffiAudio || !ffiAudio->data || ffiAudio->size == 0 ||
        !IsRustDeskCallbackOwnerActive(impl, context)) {
        return;
    }

    const Render::DecoderSessionIdentity callbackOwner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(callbackOwner);
    if (!sinkLease) {
        return;
    }

    const int channels = ffiAudio->channels > 0 ? ffiAudio->channels : 2;
    const size_t bytesPerFrame = static_cast<size_t>(channels) * 2;
    if (ffiAudio->size < bytesPerFrame * 120 ||
        (bytesPerFrame > 0 && (ffiAudio->size % bytesPerFrame) != 0)) {
        uint64_t skipped = impl->callbackAudioFrames.fetch_add(
            1, std::memory_order_relaxed) + 1;
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

    uint64_t index = impl->callbackAudioFrames.fetch_add(
        1, std::memory_order_relaxed) + 1;
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
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* cursor = static_cast<const RustDeskFfiCursorUpdate*>(cursorPtr);
    if (!context || !impl || !cursor) {
        return;
    }
    // Serialize the generation check with setSessionIdentity() and the
    // cursor-store mutation. Checking the atomic generation first and then
    // mutating later leaves a reconnect-sized TOCTOU window.
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (context->generation == 0 ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !IsRustDeskCallbackOwnerActive(impl, context)) {
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
            const bool accepted = impl->cursorStore.setShapeIfGeneration(
                context->generation, cursor->shapeId, cursor->width, cursor->height,
                cursor->hotX, cursor->hotY, rgba);
            const uint64_t index = impl->callbackCursorShape.fetch_add(
                1, std::memory_order_relaxed) + 1;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] cursor shape #%{public}llu id=%{public}llu size=%{public}dx%{public}d hot=%{public}d,%{public}d accepted=%{public}s",
                static_cast<unsigned long long>(index),
                static_cast<unsigned long long>(cursor->shapeId), cursor->width, cursor->height,
                cursor->hotX, cursor->hotY, accepted ? "yes" : "no");
            break;
        }
        case 1: {
            impl->cursorStore.setPositionIfGeneration(context->generation, cursor->x, cursor->y);
            const uint64_t index = impl->callbackCursorPosition.fetch_add(
                1, std::memory_order_relaxed) + 1;
            if (index <= 10 || index % 300 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] cursor position #%{public}llu x=%{public}d y=%{public}d",
                    static_cast<unsigned long long>(index), cursor->x, cursor->y);
            }
            break;
        }
        case 2: {
            impl->cursorStore.setVisibleIfGeneration(context->generation, cursor->visible);
            const uint64_t index = impl->callbackCursorVisibility.fetch_add(
                1, std::memory_order_relaxed) + 1;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] cursor visibility #%{public}llu visible=%{public}s",
                static_cast<unsigned long long>(index), cursor->visible ? "yes" : "no");
            break;
        }
        case 3: {
            const uint64_t index = impl->callbackCursorCacheMiss.fetch_add(
                1, std::memory_order_relaxed) + 1;
            if (index <= 10 || index % 100 == 0) {
                OH_LOG_WARN(LOG_APP,
                    "[RustDesk-FFI] cursor cache miss #%{public}llu id=%{public}llu preserve_previous=true",
                    static_cast<unsigned long long>(index),
                    static_cast<unsigned long long>(cursor->shapeId));
            }
            // Diagnostic-only update. Do not mutate the cursor store: its
            // last valid protocol shape remains the authoritative display.
            break;
        }
        default:
            break;
    }
}

void RustDeskBridge::onFfiDisplay(const void* snapshotPtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* snapshot = static_cast<const RustDeskFfiDisplaySnapshot*>(snapshotPtr);
    if (!context || !impl ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !snapshot || snapshot->version != kRustDeskDisplaySnapshotVersion ||
        snapshot->currentDisplay < 0 ||
        !IsRustDeskCallbackOwnerActive(impl, context)) {
        return;
    }

    impl->displayControl.dispatchDisplay(
        snapshot->currentDisplay,
        [&]() {
            return context->generation ==
                    impl->cursorGeneration.load(std::memory_order_acquire) &&
                context->ownerToken != 0 &&
                context->ownerToken == impl->ownerToken.load(std::memory_order_acquire) &&
                !impl->disconnectRequested.load(std::memory_order_acquire) &&
                !impl->ffiStreamEnded.load(std::memory_order_acquire) &&
                IsRustDeskCallbackOwnerActive(impl, context);
        },
        [&](const RustDeskDisplaySwitchGateDecision& decision) {
            RustDeskDisplayStateCallback callback;
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                callback = impl->displayStateCallback;
            }
            if (callback) {
                callback(decision.display);
            }
        });
}

void RustDeskBridge::onFfiAuth(int state, const char* message, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    if (!context || !impl) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        if (context->generation == 0 ||
            context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
            context->ownerToken == 0 ||
            context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
            context->admissionEpoch == 0 ||
            context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
            impl->disconnectRequested.load(std::memory_order_acquire)) {
            return;
        }
    }
    const char* eventMessage = message ? message : "RustDesk Peer authentication required";
    if (state == 0) {
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Peer 2FA accepted");
        return;
    }
    if (state == 2) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-FFI] Peer 2FA code rejected");
    } else {
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Peer 2FA pending");
    }
    impl->setState(ConnectionState::AUTHENTICATING, eventMessage);
}

void RustDeskBridge::onFfiTransportEvent(const void* eventPtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* event = static_cast<const RustDeskFfiTransportEvent*>(eventPtr);
    if (!context || !impl || !event) {
        return;
    }
    const Render::DecoderSessionIdentity callbackOwner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    // Serialize callback admission with explicit teardown. The lock is not
    // held while an owner-exclusive sink transition is requested elsewhere.
    std::unique_lock<std::mutex> admissionLock(impl->continuityAdmissionMutex);
    if (context->generation == 0 ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire)) {
        return;
    }
    RustDeskTransportEvent continuityEvent {};
    uint64_t eventAdmissionEpoch = 0;
    const uint64_t eventGeneration = context->generation;
    const uint64_t eventOwnerToken = context->ownerToken;
    const uint64_t eventSessionId = callbackOwner.sessionId;
    {
        auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(callbackOwner);
        if (!sinkLease) {
            return;
        }
        const RustDeskTransportErrorClass errorClass =
            RustDeskTransportErrorClassFromString(event->errorClass ? event->errorClass : "unknown");
        const bool networkAvailable =
            errorClass != RustDeskTransportErrorClass::NetworkDown &&
            errorClass != RustDeskTransportErrorClass::Unreachable;
        continuityEvent = RustDeskTransportEvent {
            event->state == 0 || event->state == 4,
            errorClass,
            event->networkGeneration,
            event->userInitiated,
            networkAvailable,
            rdSteadyNowMs(),
        };
        impl->ffiStreamEnded.store(true, std::memory_order_release);
        eventAdmissionEpoch = impl->ffiAdmissionEpoch.load(std::memory_order_acquire);
    }
    admissionLock.unlock();
    // The executor is the sole consumer of the action. It performs the
    // fast-quiesce transition, publishes the visible state, and schedules the
    // retained-config reconnect outside this platform callback. The admission
    // predicate is checked before every external action. In particular, a
    // synchronous state callback may call disconnect(); that reentrant call
    // invalidates the epoch without waiting on this callback's mutex, so no
    // stale action can publish or queue a reconnect after the disconnect.
    RustDeskConnectionContinuityExecutor::ActionAdmission actionAdmission =
        [impl, eventSessionId, eventGeneration, eventOwnerToken, eventAdmissionEpoch]() {
            return impl->sessionId.load(std::memory_order_acquire) == eventSessionId &&
                impl->cursorGeneration.load(std::memory_order_acquire) == eventGeneration &&
                impl->ownerToken.load(std::memory_order_acquire) == eventOwnerToken &&
                impl->ffiAdmissionEpoch.load(std::memory_order_acquire) == eventAdmissionEpoch &&
                !impl->disconnectRequested.load(std::memory_order_acquire);
        };
    (void)impl->continuityExecutor->onTransportEvent(continuityEvent,
                                                     std::move(actionAdmission));
}

void RustDeskBridge::onFfiDisconnect(int state, const char* message, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    auto* context = static_cast<RustDeskFfiCallbackContext*>(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    bool wasConnected = false;
    bool requested = false;
    bool stale = false;
    uint64_t currentGeneration = 0;
    uint64_t currentOwnerToken = 0;
    uint64_t currentAdmissionEpoch = 0;
    void* endedHandle = nullptr;
    std::shared_ptr<RustDeskBridge::Impl> keepAlive;
    if (context && context->implKeepAlive) {
        keepAlive = std::static_pointer_cast<RustDeskBridge::Impl>(
            context->implKeepAlive);
    }
    if (!context || !impl) {
        stale = true;
    } else {
        auto displayLease = impl->displayControl.acquireDisplayLease();
        std::lock_guard<std::mutex> lock(impl->mutex);
        currentGeneration = impl->cursorGeneration.load(std::memory_order_acquire);
        currentOwnerToken = impl->ownerToken.load(std::memory_order_acquire);
        currentAdmissionEpoch = impl->ffiAdmissionEpoch.load(std::memory_order_acquire);
            if (context->generation == 0 || context->generation != currentGeneration ||
            context->ownerToken == 0 || context->ownerToken != currentOwnerToken ||
            context->admissionEpoch == 0 ||
            context->admissionEpoch != currentAdmissionEpoch) {
            stale = true;
            if (context->generation != 0 &&
                impl->ffiHandleGeneration.load(std::memory_order_acquire) ==
                    context->generation) {
                endedHandle = impl->displayControl.detachHandle();
                impl->ffiHandleGeneration.store(0, std::memory_order_release);
            }
        } else {
            impl->ffiStreamEnded.store(true, std::memory_order_release);
            impl->inputForwardReady.store(false, std::memory_order_release);
            displayLease.reset();
            wasConnected = impl->state == ConnectionState::CONNECTED;
            requested = impl->disconnectRequested.load(std::memory_order_acquire);
            // disconnect() already applies the visibility transition for the
            // requested teardown. Do not repeat it after setSessionIdentity()
            // has prepared the next session's fallback shape.
            if (!requested && !impl->cursorStore.setVisibleIfGeneration(
                    context->generation, false)) {
                stale = true;
            }
            if (!stale && !requested) {
                // The FFI callback runs on the streaming thread. Move
                // ownership out here and release it on a separate thread
                // after every callback has returned. The cleanup worker is
                // retained by Impl and harvested before a new generation is
                // published.
                endedHandle = impl->displayControl.detachHandle();
                impl->ffiHandleGeneration.store(0, std::memory_order_release);
                if (endedHandle != nullptr) {
                    OH_LOG_INFO(LOG_APP,
                        "[RustDesk-FFI] scheduling stale handle cleanup=%{public}p reason=stream-ended",
                        endedHandle);
                }
            }
        }
    }
    if (endedHandle != nullptr) {
        RustDeskBridge::scheduleFfiHandleCleanup(keepAlive, endedHandle);
    }
    if (stale) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stale disconnect callback ignored generation=%{public}llu current=%{public}llu",
            context ? static_cast<unsigned long long>(context->generation) : 0ULL,
            static_cast<unsigned long long>(currentGeneration));
        return;
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
    const RustDeskContinuityState continuityState = impl->continuityExecutor->state();
    const bool continuityOwnsRecovery =
        continuityState == RustDeskContinuityState::TransportLost ||
        continuityState == RustDeskContinuityState::RetryPending ||
        continuityState == RustDeskContinuityState::ReauthRequired ||
        continuityState == RustDeskContinuityState::Terminal;
    if (impl && !continuityOwnsRecovery) {
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
    } else if (continuityOwnsRecovery) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] continuity executor owns post-transport state; legacy disconnect suppressed");
    }
    drainDeferredFfiHandles(impl);
}
#endif

RustDeskBridge::RustDeskBridge(RustDeskMode mode)
    : impl_(std::make_shared<Impl>()), mode_(mode) {
    RustDeskConnectionContinuityExecutor::Callbacks continuityCallbacks;
    continuityCallbacks.fastQuiesce = [this]() {
        applyContinuityFastQuiesce();
    };
    continuityCallbacks.publishVisibleState = [this](const std::string& event) {
        if (event == "REAUTH") {
            impl_->setState(ConnectionState::AUTHENTICATING,
                "Continuity|event=REAUTH");
        } else if (event == "FAILED" ||
                   event == "FAILED_RETRY_BUDGET_EXHAUSTED") {
            impl_->setState(ConnectionState::ERROR,
                "Continuity|event=FAILED");
        } else if (event == "WAITING_NETWORK") {
            impl_->setState(ConnectionState::DISCONNECTED,
                "Continuity|event=WAITING_NETWORK");
        } else if (event == "CONNECTED") {
            impl_->setState(ConnectionState::CONNECTED,
                "Continuity|event=CONNECTED");
        } else {
            impl_->setState(ConnectionState::RECONNECTING,
                std::string("Continuity|event=") + event);
        }
    };
    continuityCallbacks.makeAttemptTicket = [this]() {
        RustDeskConnectionContinuityExecutor::AttemptTicket ticket;
        Impl* impl = impl_.get();
        ticket.sessionId = impl->sessionId.load(std::memory_order_acquire);
        ticket.sessionGeneration = impl->cursorGeneration.load(std::memory_order_acquire);
        ticket.ownerToken = impl->ownerToken.load(std::memory_order_acquire);
        ticket.admissionEpoch = impl->ffiAdmissionEpoch.load(std::memory_order_acquire);
        ticket.attemptToken = impl->nextContinuityAttemptToken.fetch_add(
            1, std::memory_order_relaxed);
        impl->continuityAttemptToken.store(ticket.attemptToken, std::memory_order_release);
        const uint64_t sessionId = ticket.sessionId;
        const uint64_t generation = ticket.sessionGeneration;
        const uint64_t admissionEpoch = ticket.admissionEpoch;
        const uint64_t attemptToken = ticket.attemptToken;
        const uint64_t ownerToken = ticket.ownerToken;
        ticket.validator = [impl, sessionId, generation, admissionEpoch,
                            ownerToken, attemptToken]() {
            return impl->sessionId.load(std::memory_order_acquire) == sessionId &&
                impl->cursorGeneration.load(std::memory_order_acquire) == generation &&
                impl->ffiAdmissionEpoch.load(std::memory_order_acquire) == admissionEpoch &&
                impl->ownerToken.load(std::memory_order_acquire) == ownerToken &&
                impl->continuityAttemptToken.load(std::memory_order_acquire) == attemptToken &&
                !impl->disconnectRequested.load(std::memory_order_acquire);
        };
        return ticket;
    };
    continuityCallbacks.prepareAttemptTicket = [this](
        const RustDeskConnectionContinuityExecutor::AttemptTicket& source) {
        const auto prepared = prepareContinuityAttempt(source);
        return prepared.value_or(
            RustDeskConnectionContinuityExecutor::PreparedAttemptTicket {});
    };
    continuityCallbacks.startAttemptWithPreparedTicket = [this](
        const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket& ticket) {
        return startContinuityAttempt(ticket);
    };
    continuityCallbacks.cancelAttempt = [this]() {
#ifdef RUSTDESK_USE_REAL_CORE
        rustdesk_cancel_pending_connect_for_session(
            impl_->sessionId.load(std::memory_order_acquire));
#endif
    };
    continuityCallbacks.maintenancePoll = [this](uint64_t nowMs) {
        onContinuityMaintenance(nowMs);
    };
    continuityCallbacks.firstGenerationReady = [this]() {
        // First-frame commit and explicit disconnect share this short
        // admission transition. A stale callback cannot reopen S1 after
        // disconnect has won; a frame committed first is closed normally by
        // the later disconnect transition.
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (impl_->disconnectRequested.load(std::memory_order_acquire) ||
            impl_->ffiStreamEnded.load(std::memory_order_acquire) ||
            impl_->firstFrameCommittedToken.load(std::memory_order_acquire) == 0) {
            return;
        }
        impl_->continuityQuiesce.reopenPresentationAfterFirstFrame();
        impl_->continuityQuiesce.reopenAudioAfterPrebuffer();
        impl_->inputForwardReady.store(true, std::memory_order_release);
        impl_->awaitingFirstGenerationFrame.store(false, std::memory_order_release);
    };
    impl_->continuityExecutor->setCallbacks(std::move(continuityCallbacks));
    const char* modeLabel = (mode == RustDeskMode::IPC) ? "IPC" :
        (mode == RustDeskMode::FFI ? "FFI" : "EXPERIMENTAL");
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDeskBridge created (mode=%{public}s)", modeLabel);
}

void RustDeskBridge::setSessionIdentity(uint64_t sessionId) {
    const uint64_t generation =
        g_nextRustDeskCursorGeneration.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
        impl_->inputForwardReady.store(false, std::memory_order_release);
        impl_->continuityAttemptToken.store(0, std::memory_order_release);
        impl_->continuityNetworkClaimToken.store(0, std::memory_order_release);
        impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
        impl_->continuityNetworkCallCancelled.store(true, std::memory_order_release);
        impl_->firstFrameClaimToken.store(0, std::memory_order_release);
        impl_->firstFrameCommittedToken.store(0, std::memory_order_release);
    }
    auto displayLease = impl_->displayControl.acquireDisplayLease();
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->sessionId.store(sessionId, std::memory_order_release);
    impl_->cursorGeneration.store(generation, std::memory_order_release);
    impl_->continuityExecutor->begin(sessionId, generation, rdSteadyNowMs());
    impl_->continuityQuiesce.reopen();
    impl_->awaitingFirstGenerationFrame.store(false, std::memory_order_release);
    impl_->inputForwardReady.store(false, std::memory_order_release);
    impl_->ownerToken.store(0, std::memory_order_release);
    impl_->callbackVideoFrames.store(0, std::memory_order_release);
    impl_->callbackVideoBytes.store(0, std::memory_order_release);
    impl_->callbackKeyframes.store(0, std::memory_order_release);
    impl_->callbackAudioFrames.store(0, std::memory_order_release);
    impl_->callbackCursorShape.store(0, std::memory_order_release);
    impl_->callbackCursorPosition.store(0, std::memory_order_release);
    impl_->callbackCursorVisibility.store(0, std::memory_order_release);
    impl_->callbackCursorCacheMiss.store(0, std::memory_order_release);
    impl_->callbackCodec.store(-1, std::memory_order_release);
    impl_->callbackWidth.store(0, std::memory_order_release);
    impl_->callbackHeight.store(0, std::memory_order_release);
    impl_->lastFrameAtMs.store(0, std::memory_order_release);
    {
        std::lock_guard<std::mutex> cadenceLock(impl_->cadenceMutex);
        impl_->cadenceInitialized = false;
        impl_->cadenceWindowFrames = 0;
        impl_->cadenceWindowMaxGapMs = 0;
        impl_->cadenceGapCount = 0;
    }
    // A reconnect must not inherit pending/confirmed/ready display state or
    // input blocking from S1. Lease::reset() performs that gate reset while
    // the non-reentrant display lease is held; do not call the coordinator's
    // locking resetDisplayState() again before this lease is released.
    displayLease.reset();
    impl_->cursorStore.reset(sessionId, "rustdesk", generation);
    // RustDesk does not guarantee that an unchanged cursor shape is repeated
    // after every UI/surface handoff. This local bootstrap shape is explicitly
    // marked non-authoritative so ArkUI can keep a stable circle affordance
    // until the protocol supplies the real cursor bitmap.
    impl_->cursorStore.setFallbackShape();
    impl_->cursorStore.setVisible(true);
}

void RustDeskBridge::setSessionOwnerToken(uint64_t ownerToken) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->ownerToken.store(ownerToken, std::memory_order_release);
}

void RustDeskBridge::setContinuityGenerationCallback(
    ContinuityGenerationCallback callback) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->continuityGenerationCallback = std::move(callback);
}

void RustDeskBridge::onNetworkChanged(bool available, uint64_t networkGeneration) {
    impl_->continuityExecutor->onNetworkAvailable(
        available, networkGeneration, rdSteadyNowMs());
}

RustDeskContinuityQuiesceSnapshot RustDeskBridge::continuityQuiesceSnapshot() const {
    return impl_->continuityQuiesce.snapshot();
}

std::optional<RustDeskConnectionContinuityExecutor::PreparedAttemptTicket>
RustDeskBridge::prepareContinuityAttempt(
    const RustDeskConnectionContinuityExecutor::AttemptTicket& source) {
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void(int)> stageHook;
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        stageHook = impl_->continuityAttemptStageHook;
    }
    if (stageHook) {
        stageHook(0); // source validation/prepare boundary
    }
#endif

    RustDeskConnectionContinuityExecutor::PreparedAttemptTicket prepared;
    const uint64_t generation =
        g_nextRustDeskCursorGeneration.fetch_add(1, std::memory_order_relaxed);
    const uint64_t attemptToken =
        impl_->nextContinuityAttemptToken.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        // The source ticket is consumed exactly once. Its validator includes
        // the old generation/token and must pass before this atomic rotation.
        if (!source.valid() || !source.validator || !source.validator() ||
            source.sessionId != impl_->sessionId.load(std::memory_order_acquire) ||
            source.sessionGeneration != impl_->cursorGeneration.load(std::memory_order_acquire) ||
            source.ownerToken != impl_->ownerToken.load(std::memory_order_acquire) ||
            source.admissionEpoch != impl_->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
            impl_->disconnectRequested.load(std::memory_order_acquire)) {
            return std::nullopt;
        }
        const uint64_t sessionId = source.sessionId;
        const uint64_t ownerToken = source.ownerToken;
        const uint64_t admissionEpoch = source.admissionEpoch;
        impl_->cursorGeneration.store(generation, std::memory_order_release);
        impl_->continuityAttemptToken.store(attemptToken, std::memory_order_release);
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
        impl_->inputForwardReady.store(false, std::memory_order_release);
        impl_->firstFrameClaimToken.store(0, std::memory_order_release);
        impl_->firstFrameCommittedToken.store(0, std::memory_order_release);
        impl_->awaitingFirstGenerationFrame.store(
            mode_ == RustDeskMode::FFI, std::memory_order_release);
        prepared.sessionId = sessionId;
        prepared.sessionGeneration = generation;
        prepared.ownerToken = ownerToken;
        prepared.admissionEpoch = admissionEpoch;
        prepared.attemptToken = attemptToken;
        prepared.validator = [impl = impl_.get(), sessionId, generation,
                              ownerToken, admissionEpoch, attemptToken]() {
            return impl->sessionId.load(std::memory_order_acquire) == sessionId &&
                impl->cursorGeneration.load(std::memory_order_acquire) == generation &&
                impl->ownerToken.load(std::memory_order_acquire) == ownerToken &&
                impl->ffiAdmissionEpoch.load(std::memory_order_acquire) == admissionEpoch &&
                impl->continuityAttemptToken.load(std::memory_order_acquire) == attemptToken &&
                !impl->disconnectRequested.load(std::memory_order_acquire);
        };
    }

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (stageHook) {
        stageHook(1); // rotated ticket is visible, before external activation
    }
#endif
    if (!prepared.valid() || !prepared.validator()) {
        return std::nullopt;
    }

    auto displayLease = impl_->displayControl.acquireDisplayLease();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->callbackVideoFrames.store(0, std::memory_order_release);
        impl_->callbackVideoBytes.store(0, std::memory_order_release);
        impl_->callbackKeyframes.store(0, std::memory_order_release);
        impl_->callbackAudioFrames.store(0, std::memory_order_release);
        impl_->callbackCodec.store(-1, std::memory_order_release);
        impl_->callbackWidth.store(0, std::memory_order_release);
        impl_->callbackHeight.store(0, std::memory_order_release);
        impl_->lastFrameAtMs.store(0, std::memory_order_release);
    }
    displayLease.reset();
    impl_->cursorStore.reset(prepared.sessionId, "rustdesk", prepared.sessionGeneration);
    impl_->cursorStore.setFallbackShape();
    impl_->cursorStore.setVisible(true);

    ContinuityGenerationCallback callback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        callback = impl_->continuityGenerationCallback;
    }
    const bool activated = !callback ||
        (prepared.validator() && callback(prepared.sessionId,
                                          prepared.sessionGeneration,
                                          prepared.ownerToken));
    if (!activated || !prepared.validator()) {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (impl_->continuityAttemptToken.load(std::memory_order_acquire) ==
                prepared.attemptToken) {
            impl_->continuityAttemptToken.store(0, std::memory_order_release);
        }
        return std::nullopt;
    }
    impl_->continuityQuiesce.reopenGenerationAdmission();
    return prepared;
}

bool RustDeskBridge::startContinuityAttempt(
    const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket& ticket) {
    if (!ticket.valid() || !ticket.validator || !ticket.validator()) {
        return false;
    }
#ifdef RUSTDESK_USE_REAL_CORE
    harvestCompletedFfiWorkers(impl_.get());
#endif
    completeContinuityOwnerQuiesce(impl_.get());
    const RustDeskContinuityQuiesceSnapshot quiesce =
        impl_->continuityQuiesce.snapshot();
    if (impl_->continuityQuiesceActive.load(std::memory_order_acquire) ||
        (quiesce.deferredDestroyRequested && !quiesce.deferredDestroyComplete)) {
        // A reconnect must not publish a fresh FFI/display generation while
        // the old callback context is still owned by the deferred joiner.
        // Returning false lets the policy retain its bounded retry budget;
        // the next timer observes completion without blocking this worker.
        return false;
    }
    ConnectionConfig reconnectConfig;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        reconnectConfig = impl_->config;
    }
    if (reconnectConfig.host.empty() && !reconnectConfig.rdDirectIp) {
        return false;
    }
 #if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void(int)> stageHook;
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        stageHook = impl_->continuityAttemptStageHook;
    }
    if (stageHook) {
        stageHook(2); // immediately before connect side effect/call count
    }
    if (!ticket.validator()) {
        return false;
    }
#endif
    bool networkClaimed = false;
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        // This is the irrevocable boundary for a continuity network side
        // effect. A disconnect that acquires the same lock first invalidates
        // the prepared ticket and produces zero calls. Once this claim wins,
        // disconnect can cancel/discard the result but never lets it publish.
        if (ticket.validator() &&
            !impl_->continuityNetworkCallCancelled.load(std::memory_order_acquire)) {
            impl_->continuityReconnectPending.store(true, std::memory_order_release);
            impl_->continuityAttemptActive.store(true, std::memory_order_release);
            impl_->continuityNetworkClaimToken.store(ticket.attemptToken,
                                                      std::memory_order_release);
            impl_->continuityNetworkCallActive.store(true, std::memory_order_release);
            networkClaimed = true;
            impl_->continuityConnectCallCount.fetch_add(1, std::memory_order_acq_rel);
        }
    }
    if (!networkClaimed) {
        return false;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    {
        std::function<void(int)> claimHook;
        {
            std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
            claimHook = impl_->continuityAttemptStageHook;
        }
        if (claimHook) {
            claimHook(3); // claim won, immediately before the external call
        }
    }
#endif
    int ret = 0;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<int(uint64_t, uint64_t)> testConnectHook;
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        testConnectHook = impl_->continuityConnectResultHook;
    }
    if (testConnectHook) {
        ret = testConnectHook(ticket.sessionGeneration, ticket.attemptToken);
        const bool cancelled = impl_->continuityNetworkCallCancelled.load(
            std::memory_order_acquire) || !ticket.validator();
        impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
        impl_->continuityAttemptActive.store(false, std::memory_order_release);
        impl_->continuityReconnectPending.store(false, std::memory_order_release);
        impl_->continuityExecutor->recordAttemptResult(ret == 0 && !cancelled,
                                                      rdSteadyNowMs());
        return ret == 0 && !cancelled;
    }
#endif
    ret = connectInternal(reconnectConfig, &ticket);
    impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
    if (ret != 0) {
        impl_->continuityAttemptActive.store(false, std::memory_order_release);
        impl_->continuityReconnectPending.store(false, std::memory_order_release);
        impl_->continuityExecutor->recordAttemptResult(false, rdSteadyNowMs());
        return false;
    }
    return true;
}

void RustDeskBridge::applyContinuityFastQuiesce() {
    const uint64_t quiesceStartedAt = rdSteadyNowMs();
    // The synchronous portion is deliberately limited to atomics and the
    // local bounded state transition. Platform Stop/Flush, FFI quiesce and
    // owner-exclusive teardown can re-enter or block, so they are handed to
    // an owned worker below instead of extending the 500 ms transport-loss
    // budget.
    impl_->continuityQuiesce.closeForTransportLoss();
    impl_->ffiStreamEnded.store(true, std::memory_order_release);
    impl_->inputForwardReady.store(false, std::memory_order_release);
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI) {
        // Transport loss invalidates the old stream before the continuity
        // worker rotates its generation. Detach the exact opaque handle now;
        // otherwise connectInternal() sees a still-owned S1 handle and
        // rejects every S2 attempt with the stale-resource error.
        void* endedHandle = nullptr;
        {
            auto displayLease = impl_->displayControl.acquireDisplayLease();
            endedHandle = impl_->displayControl.detachHandle();
            impl_->ffiHandleGeneration.store(0, std::memory_order_release);
            displayLease.reset();
        }
        if (endedHandle != nullptr) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] transport quiesce detached handle=%{public}p",
                endedHandle);
            scheduleFfiHandleCleanup(impl_, endedHandle);
        }
    }
#endif
    const Render::DecoderSessionIdentity owner {
        impl_->sessionId.load(std::memory_order_acquire),
        impl_->cursorGeneration.load(std::memory_order_acquire),
        impl_->ownerToken.load(std::memory_order_acquire),
    };
    if (owner.valid()) {
        {
            std::lock_guard<std::mutex> transitionLock(
                impl_->continuityOwnerTransitionMutex);
            impl_->pendingContinuityOwner = owner;
        }

        bool launchDeferred = false;
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            if (!impl_->continuityQuiesceActive.load(std::memory_order_acquire)) {
                // A completed worker remains joinable until its owner
                // harvests it. Joining here is safe because Done is published
                // before the worker exits and prevents unbounded thread
                // accumulation across repeated transport losses.
                if (impl_->continuityQuiesceThread.joinable() &&
                    impl_->continuityQuiesceDone.load(std::memory_order_acquire)) {
                    impl_->continuityQuiesceThread.join();
                    impl_->continuityQuiesceDone.store(false, std::memory_order_release);
                }
                impl_->continuityQuiesceActive.store(true, std::memory_order_release);
                impl_->continuityQuiesceDone.store(false, std::memory_order_release);
                const auto doneFence = std::make_shared<RustDeskCompletionFence>(false);
                impl_->continuityQuiesceDoneFence = doneFence;
                launchDeferred = true;
                const auto keepAlive = impl_;
                try {
                    impl_->continuityQuiesceThread = std::thread(
                        [keepAlive, owner, mode = mode_, doneFence]() {
                        // Quiesce is a lifecycle barrier. Even a platform or
                        // audio callback exception must publish completion so
                        // the deferred owner can join the worker and release
                        // the retained Impl instead of spinning forever.
                        try {
#ifdef RUSTDESK_USE_REAL_CORE
                            auto handleLease = keepAlive->displayControl.acquireHandle();
                            if (mode == RustDeskMode::FFI && handleLease) {
                                const uint32_t released = rustdesk_quiesce_session(handleLease.get());
                                if (released > 0) {
                                    OH_LOG_INFO(LOG_APP,
                                        "[RustDesk-FFI] transport quiesce released held_keys=%{public}u",
                                        released);
                                }
                            }
#else
                            (void)mode;
#endif
                            // Stop/flush the old audio queue outside the transport
                            // callback and outside the owner transition lock.
                            AudioPlayerNapi::SuspendActiveNative(owner);
                            RustDeskBridge::completeContinuityOwnerQuiesce(keepAlive.get());
                        } catch (...) {
                            OH_LOG_ERROR(LOG_APP,
                                "[RustDesk] continuity quiesce worker callback failed");
                        }
#ifndef RUSTDESK_USE_REAL_CORE
                        // IPC/no-core has no FFI callback context whose join
                        // fence must be awaited.
                        keepAlive->continuityQuiesce.markDeferredDestroyComplete();
#endif
                        keepAlive->continuityQuiesceDone.store(true, std::memory_order_release);
                        doneFence->store(true, std::memory_order_release);
                            keepAlive->continuityQuiesceActive.store(false, std::memory_order_release);
                        });
                } catch (const std::exception& ex) {
                    impl_->continuityQuiesceActive.store(false, std::memory_order_release);
                    impl_->continuityQuiesceDone.store(true, std::memory_order_release);
                    doneFence->store(true, std::memory_order_release);
                    OH_LOG_ERROR(LOG_APP,
                        "[RustDesk] continuity quiesce worker start failed: %{public}s",
                        ex.what());
                } catch (...) {
                    impl_->continuityQuiesceActive.store(false, std::memory_order_release);
                    impl_->continuityQuiesceDone.store(true, std::memory_order_release);
                    doneFence->store(true, std::memory_order_release);
                    OH_LOG_ERROR(LOG_APP,
                        "[RustDesk] continuity quiesce worker start failed");
                }
            }
        }
        (void)launchDeferred;
    }
    impl_->continuityQuiesce.recordFastQuiesceDuration(
        rdSteadyNowMs() - quiesceStartedAt);
}

void RustDeskBridge::completeContinuityOwnerQuiesce(RustDeskBridge::Impl* impl) {
    if (!impl) {
        return;
    }
    Render::DecoderSessionIdentity pendingOwner;
    {
        std::lock_guard<std::mutex> transitionLock(
            impl->continuityOwnerTransitionMutex);
        pendingOwner = impl->pendingContinuityOwner;
    }
    if (!pendingOwner.valid()) {
        return;
    }
    auto ownerTransition = Render::SharedSessionSinkOwnerLease().tryAcquireExclusive();
    if (!ownerTransition) {
        return;
    }
    if (ownerTransition.activeSnapshot() != pendingOwner) {
        std::lock_guard<std::mutex> transitionLock(
            impl->continuityOwnerTransitionMutex);
        impl->pendingContinuityOwner = Render::DecoderSessionIdentity {};
        return;
    }
    (void)ownerTransition.beginDeactivate(pendingOwner);
    std::lock_guard<std::mutex> transitionLock(
        impl->continuityOwnerTransitionMutex);
    impl->pendingContinuityOwner = Render::DecoderSessionIdentity {};
}

void RustDeskBridge::onContinuityMaintenance(uint64_t nowMs) {
#ifdef RUSTDESK_USE_REAL_CORE
    // A callback-thread fallback may have retained a handle after a transient
    // thread-allocation failure.  Maintenance runs on the continuity worker,
    // never on the FFI stream callback, so it is a safe place to reclaim any
    // fence that has since completed.
    drainDeferredFfiHandles(impl_.get());
    harvestCompletedFfiWorkers(impl_.get());
#endif
    completeContinuityOwnerQuiesce(impl_.get());
    const Render::DecoderSessionIdentity owner {
        impl_->sessionId.load(std::memory_order_acquire),
        impl_->cursorGeneration.load(std::memory_order_acquire),
        impl_->ownerToken.load(std::memory_order_acquire),
    };
    if (owner.valid() && impl_->continuityQuiesce.audioAllowed()) {
        (void)AudioPlayerNapi::PollActiveAudioInactivity(owner, nowMs);
    }
}

uint64_t RustDeskBridge::sessionGeneration() const {
    return impl_->cursorGeneration.load(std::memory_order_acquire);
}

bool RustDeskBridge::submitTwoFactorCode(const std::string& code) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI) {
        const uint64_t sessionId = impl_->sessionId.load(std::memory_order_acquire);
        return rustdesk_submit_2fa_for_session(sessionId, code.c_str());
    }
#else
    (void)code;
#endif
    return false;
}

RustDeskDiagnosticsStats RustDeskBridge::getDiagnostics() const {
    RustDeskDiagnosticsStats result;
    result.sessionId = impl_->sessionId.load(std::memory_order_acquire);
    result.receivedFrames = impl_->callbackVideoFrames.load(std::memory_order_acquire);
    result.receivedBytes = impl_->callbackVideoBytes.load(std::memory_order_acquire);
    result.keyframes = impl_->callbackKeyframes.load(std::memory_order_acquire);
    result.lastFrameAtMs = impl_->lastFrameAtMs.load(std::memory_order_acquire);
    result.codec = impl_->callbackCodec.load(std::memory_order_acquire);
    result.width = impl_->callbackWidth.load(std::memory_order_acquire);
    result.height = impl_->callbackHeight.load(std::memory_order_acquire);
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        RustDeskFfiStreamStats ffiStats {};
        const bool snapshotRead = rustdesk_get_stream_stats(handleLease.get(), &ffiStats);
        if (snapshotRead && ffiStats.version == kRustDeskStreamStatsVersion) {
            result.supported = true;
            result.latencyMs = ffiStats.test_delay_count > 0 ?
                static_cast<int>(ffiStats.last_delay_ms) : -1;
            result.targetBitrateKbps = static_cast<int>(ffiStats.target_bitrate_kbps);
            result.videoMessages = ffiStats.video_messages;
            result.audioFrames = ffiStats.audio_frames;
            result.cadenceGaps = ffiStats.cadence_gaps;
            result.maxCadenceGapMs = ffiStats.max_cadence_gap_ms;
            result.testDelayCount = ffiStats.test_delay_count;
            if (result.codec < 0) result.codec = ffiStats.actual_codec;
            if (result.width <= 0) result.width = ffiStats.width;
            if (result.height <= 0) result.height = ffiStats.height;
            result.connectionPath = ffiStats.connection_path;
        } else if (snapshotRead) {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] stream diagnostics snapshot rejected: unsupported ABI version=%{public}u",
                ffiStats.version);
        }
    }
#endif
    return result;
}

RustDeskDisplayCapabilities RustDeskBridge::getDisplayCapabilities() const {
    RustDeskDisplayCapabilities result;
#ifdef RUSTDESK_USE_REAL_CORE
    RustDeskDisplaySwitchGateSnapshot gate;
    const bool queried = impl_->displayControl.queryDisplayState(
        [&]() {
            return mode_ == RustDeskMode::FFI &&
                !impl_->disconnectRequested.load(std::memory_order_acquire) &&
                !impl_->ffiStreamEnded.load(std::memory_order_acquire);
        },
        [&](void* handle) {
            RustDeskFfiDisplaySnapshot snapshot {};
            RustDeskFfiResolution resolutions[32] {};
            if (!rustdesk_get_display_snapshot(handle, &snapshot, resolutions, 32) ||
                snapshot.version != kRustDeskDisplaySnapshotVersion) {
                return false;
            }
            result.supported = true;
            result.currentDisplay = snapshot.currentDisplay;
            result.width = snapshot.width;
            result.height = snapshot.height;
            result.originalWidth = snapshot.originalWidth;
            result.originalHeight = snapshot.originalHeight;
            result.scaleMilli = snapshot.scaleMilli;
            result.geometryEpoch = snapshot.geometryEpoch;
            const size_t count = std::min<size_t>(snapshot.resolutionCount, 32);
            result.resolutions.reserve(count);
            for (size_t index = 0; index < count; ++index) {
                if (resolutions[index].width > 0 && resolutions[index].height > 0) {
                    result.resolutions.push_back({resolutions[index].width, resolutions[index].height});
                }
            }
            RustDeskFfiDisplayInfoSnapshot ffiDisplays[16] {};
            RustDeskFfiResolution allResolutions[16 * 32] {};
            size_t displayCount = 0;
            size_t resolutionCount = 0;
            if (rustdesk_get_display_list(handle, ffiDisplays, 16, allResolutions,
                                          16 * 32, &displayCount, &resolutionCount)) {
                const size_t safeDisplayCount = std::min<size_t>(displayCount, 16);
                const size_t safeResolutionCount = std::min<size_t>(resolutionCount, 16 * 32);
                result.displays.reserve(safeDisplayCount);
                for (size_t index = 0; index < safeDisplayCount; ++index) {
                    const auto& ffiDisplay = ffiDisplays[index];
                    RustDeskDisplayInfo display;
                    display.display = ffiDisplay.display;
                    display.x = ffiDisplay.x;
                    display.y = ffiDisplay.y;
                    display.width = ffiDisplay.width;
                    display.height = ffiDisplay.height;
                    display.originalWidth = ffiDisplay.originalWidth;
                    display.originalHeight = ffiDisplay.originalHeight;
                    display.scaleMilli = ffiDisplay.scaleMilli;
                    display.online = ffiDisplay.online != 0;
                    display.cursorEmbedded = ffiDisplay.cursorEmbedded != 0;
                    const size_t nameLength =
                        std::min<size_t>(ffiDisplay.nameLen, sizeof(ffiDisplay.name));
                    display.name.assign(
                        reinterpret_cast<const char*>(ffiDisplay.name), nameLength);
                    const size_t offset =
                        std::min<size_t>(ffiDisplay.resolutionOffset, safeResolutionCount);
                    const size_t countForDisplay = std::min<size_t>(
                        ffiDisplay.resolutionCount, safeResolutionCount - offset);
                    display.resolutions.reserve(countForDisplay);
                    for (size_t resolutionIndex = 0;
                         resolutionIndex < countForDisplay;
                         ++resolutionIndex) {
                        const auto& resolution = allResolutions[offset + resolutionIndex];
                        if (resolution.width > 0 && resolution.height > 0) {
                            display.resolutions.push_back(
                                {resolution.width, resolution.height});
                        }
                    }
                    result.displays.push_back(std::move(display));
                }
            }
            // A peer may expose only current-display geometry. Synthesize a
            // one-entry catalog when the complete list is unavailable.
            if (result.displays.empty()) {
                RustDeskDisplayInfo display;
                display.display = result.currentDisplay;
                display.width = result.width;
                display.height = result.height;
                display.originalWidth = result.originalWidth;
                display.originalHeight = result.originalHeight;
                display.scaleMilli = result.scaleMilli;
                display.online = true;
                display.resolutions = result.resolutions;
                result.displays.push_back(std::move(display));
            }
            return true;
        },
        gate);
    if (!queried) {
        return result;
    }
    result.switchGeneration = gate.generation;
    result.readySwitchGeneration = gate.readyGeneration;
    result.pendingDisplay = gate.pendingDisplay;
    result.inputBlocked = gate.inputBlocked;
#endif
    return result;
}

RustDeskDisplaySwitchRequest RustDeskBridge::beginDisplaySwitch(int display) {
    RustDeskDisplaySwitchRequest result;
#ifdef RUSTDESK_USE_REAL_CORE
    // Rust owns this as one latest-wins ControlInbox transaction. Keeping the
    // official switch/capture/refresh sequence behind one fenced FFI call
    // prevents rapid selections from interleaving partial triples or racing
    // teardown of the opaque Rust client.
    const RustDeskDisplayControlRequest request =
        impl_->displayControl.beginDisplaySwitch(
            display,
            [&]() {
                return mode_ == RustDeskMode::FFI && display < 16 &&
                    !impl_->disconnectRequested.load(std::memory_order_acquire) &&
                    !impl_->ffiStreamEnded.load(std::memory_order_acquire);
            },
            [](void* handle, int target) {
                return rustdesk_switch_display(handle, target);
            });
    result.accepted = request.accepted;
    result.generation = request.generation;
#else
    (void)display;
#endif
    return result;
}

bool RustDeskBridge::switchDisplay(int display) {
    return beginDisplaySwitch(display).accepted;
}

bool RustDeskBridge::captureDisplays(const std::vector<int>& displays) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_capture_displays(
            handleLease.get(),
            displays.empty() ? nullptr : displays.data(),
            displays.size());
    }
#else
    (void)displays;
#endif
    return false;
}

bool RustDeskBridge::refreshVideoDisplay(int display) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_refresh_video_display(handleLease.get(), display);
    }
#else
    (void)display;
#endif
    return false;
}

bool RustDeskBridge::changeDisplayResolution(int display, int width, int height) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_change_display_resolution(
            handleLease.get(), display, width, height);
    }
#endif
    return false;
}

bool RustDeskBridge::sendTouchScale(int scale) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_send_touch_scale(handleLease.get(), scale);
    }
#endif
    return false;
}

bool RustDeskBridge::sendTouchPan(int phase, int x, int y) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_send_touch_pan(handleLease.get(), phase, x, y);
    }
#endif
    return false;
}

RemoteCursorSnapshot RustDeskBridge::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
}

RustDeskBridge::~RustDeskBridge() {
    bool hasFfiHandle = false;
    bool hasFfiConnectThread = false;
    bool hasFfiCleanupThreads = false;
    bool hasContinuityQuiesceThread = false;
    bool hasIpcFd = false;
    bool hasExperimentalFd = false;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasContinuityQuiesceThread = impl_->continuityQuiesceThread.joinable();
        hasIpcFd = impl_->ipcFd >= 0;
        hasExperimentalFd = impl_->sockFd >= 0;
    }
#ifdef RUSTDESK_USE_REAL_CORE
    hasFfiHandle = impl_->displayControl.hasHandle();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasFfiConnectThread = impl_->ffiConnectThread.joinable();
        hasFfiCleanupThreads = !impl_->ffiCleanupThreads.empty();
    }
#endif
    if (hasFfiHandle || hasFfiConnectThread || hasFfiCleanupThreads ||
        hasContinuityQuiesceThread ||
        hasIpcFd || hasExperimentalFd ||
        getState() != ConnectionState::DISCONNECTED) {
        disconnect();
    }
    // Continuity callback closures retain Impl while a worker is active. Drop
    // that back-reference before shared executor teardown so a deferred
    // worker cannot form an Impl->executor->callback->Impl cycle.
    impl_->continuityExecutor->setCallbacks({});
    impl_->continuityExecutor->shutdown();
    (void)RustDeskConnectionContinuityExecutor::shutdownDeferredWithin(
        std::chrono::milliseconds(500));
    std::thread continuityQuiesceThread;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        continuityQuiesceThread = std::move(impl_->continuityQuiesceThread);
    }
    if (continuityQuiesceThread.joinable()) {
        if (continuityQuiesceThread.get_id() == std::this_thread::get_id()) {
            // The no-real-core test/IPC path can still re-enter disconnect
            // from an audio callback. Move the current worker to the same
            // owned joiner used by FFI instead of ever self-joining or
            // destroying a joinable thread object.
            rustDeskThreadJoiner().enqueue(
                std::move(continuityQuiesceThread), impl_, {},
                impl_->continuityQuiesceDoneFence);
        } else if (impl_->continuityQuiesceDone.load(std::memory_order_acquire)) {
            // The done fence is the only condition under which this owner may
            // join inline. A worker that has not reached the fence stays in
            // the explicit join owner so destruction never extends the
            // transport-loss caller budget.
            continuityQuiesceThread.join();
        } else {
            rustDeskThreadJoiner().enqueue(
                std::move(continuityQuiesceThread), impl_, {},
                impl_->continuityQuiesceDoneFence);
        }
    }
#ifdef RUSTDESK_USE_REAL_CORE
    rustdesk_shutdown_deferred_joiner();
#endif
    // The C++ callback/thread owner has the same bounded app-scope contract
    // as the Rust FFI reaper. If a cooperative worker is still blocked, the
    // owner remains observable for a later drain instead of extending bridge
    // destruction into an unbounded join.
    (void)shutdownRustDeskThreadJoinerWithin(std::chrono::milliseconds(500));
    (void)shutdownRustDeskIpcJoinerWithin(std::chrono::milliseconds(500));
    (void)shutdownRustDeskIpcHelperOwnerWithin(std::chrono::milliseconds(500));
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

    OH_LOG_INFO(LOG_APP,
                "[RustDesk-IPC] Connected to helper pathId=%{public}s fd=%{public}d",
                SafeLog::HashForLog(socketPath).c_str(), fd);
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
    return connectInternal(cfg, nullptr);
}

int RustDeskBridge::connectInternal(
    const ConnectionConfig& cfg,
    const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket* continuityTicket) {
    const bool continuityReconnect = continuityTicket != nullptr;
    const uint64_t continuityAttemptToken = continuityTicket
        ? continuityTicket->attemptToken : 0;
    const uint64_t continuitySessionId = continuityTicket
        ? continuityTicket->sessionId : 0;
    const uint64_t continuityGeneration = continuityTicket
        ? continuityTicket->sessionGeneration : 0;
    const uint64_t continuityOwnerToken = continuityTicket
        ? continuityTicket->ownerToken : 0;
    const auto continuityFenceValid = [impl = impl_.get(), continuityReconnect,
                                       continuityAttemptToken, continuitySessionId,
                                       continuityOwnerToken, continuityGeneration]() {
        return !continuityReconnect ||
            (impl->sessionId.load(std::memory_order_acquire) == continuitySessionId &&
             impl->cursorGeneration.load(std::memory_order_acquire) == continuityGeneration &&
             impl->ownerToken.load(std::memory_order_acquire) == continuityOwnerToken &&
             impl->continuityAttemptToken.load(std::memory_order_acquire) ==
                 continuityAttemptToken &&
             !impl->continuityNetworkCallCancelled.load(std::memory_order_acquire) &&
             !impl->disconnectRequested.load(std::memory_order_acquire));
    };
    bool hasFfiHandle = false;
    bool hasFfiConnectThread = false;
    bool hasFfiCleanupThreads = false;
    bool hasContinuityQuiesceThread = false;
    bool hasIpcFd = false;
    bool hasExperimentalFd = false;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        // A completed worker is safely harvestable by the next quiesce or
        // destructor. Only an active worker must fence a continuity attempt;
        // treating every joinable (already done) thread as stale would reject
        // the first reconnect forever.
        hasContinuityQuiesceThread =
            impl_->continuityQuiesceActive.load(std::memory_order_acquire);
        hasIpcFd = impl_->ipcFd >= 0;
        hasExperimentalFd = impl_->sockFd >= 0;
    }
#ifdef RUSTDESK_USE_REAL_CORE
    harvestCompletedFfiWorkers(impl_.get());
    hasFfiHandle = impl_->displayControl.hasHandle();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasFfiConnectThread = impl_->ffiConnectThread.joinable();
        hasFfiCleanupThreads = !impl_->ffiCleanupThreads.empty();
        hasFfiCleanupThreads = hasFfiCleanupThreads ||
            impl_->ffiDeferredJoinCount.load(std::memory_order_acquire) != 0;
    }
#endif
    if (hasFfiHandle || hasFfiConnectThread || hasFfiCleanupThreads ||
        hasContinuityQuiesceThread ||
        hasIpcFd || hasExperimentalFd ||
        (!continuityReconnect && getState() != ConnectionState::DISCONNECTED)) {
        if (continuityReconnect) {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] continuity ticket rejected while previous resources remain");
            return -46;
        }
        disconnectImpl(true);
    }
    // setSessionIdentity() can run before connect() tears down a previous FFI
    // stream. Re-seed the store after that teardown so the old disconnect
    // callback cannot leave the new session hidden or carry old revisions.
    const uint64_t sessionId = impl_->sessionId.load(std::memory_order_acquire);
    const uint64_t generation = impl_->cursorGeneration.load(std::memory_order_acquire);
    if (sessionId != 0 && generation != 0) {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->cursorStore.reset(sessionId, "rustdesk", generation);
        impl_->cursorStore.setFallbackShape();
        impl_->cursorStore.setVisible(true);
    }
    {
        // connectInternal may be entered by the continuity worker while a
        // concurrent disconnect or diagnostics read is still using the
        // retained configuration.  Publish the snapshot under the same mutex
        // used by reconnectConfig and the test seam.
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->config = cfg;
    }
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (continuityReconnect) {
            // The ticket was admitted before entering connectInternal. Do not
            // clear its disconnect fence or manufacture a second continuity
            // owner here; a user connect is the only path allowed to reopen
            // an admission epoch.
            if (!continuityTicket->validator || !continuityTicket->validator()) {
                return -47;
            }
        } else {
            // Every newly registered FFI callback stream gets a new admission
            // epoch, including same-session reconnects.
            impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
            impl_->disconnectRequested.store(false, std::memory_order_release);
            impl_->ffiStreamEnded.store(false, std::memory_order_release);
            impl_->continuityAttemptToken.store(0, std::memory_order_release);
            impl_->continuityNetworkClaimToken.store(0, std::memory_order_release);
            impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
            impl_->continuityNetworkCallCancelled.store(false, std::memory_order_release);
        }
    }
    impl_->inputForwardReady.store(false, std::memory_order_release);
    if (continuityReconnect) {
        if (!continuityFenceValid()) {
            impl_->continuityReconnectPending.store(false, std::memory_order_release);
            impl_->continuityAttemptActive.store(false, std::memory_order_release);
            return -48;
        }
        impl_->continuityReconnectPending.store(false, std::memory_order_release);
    } else {
        impl_->continuityQuiesce.reopen();
    }
    impl_->awaitingFirstGenerationFrame.store(
        mode_ == RustDeskMode::FFI, std::memory_order_release);
    const uint64_t serial = ++impl_->connectSerial;
    impl_->setState(ConnectionState::CONNECTING, "Connecting...");
    const std::string connectionStrategy = cfg.rdConnectionStrategy.empty()
        ? (cfg.rdDirectIp ? "direct_ip" : "force_relay")
        : cfg.rdConnectionStrategy;

    if (connectionStrategy == "auto") {
        const std::string message =
            "RDERR|stage=strategy|code=auto_unavailable|attempt=" +
            std::to_string(sessionId) +
            "|detail=automatic path is unavailable until NAT and relay fallback validation completes";
        impl_->setState(ConnectionState::ERROR, message);
        OH_LOG_WARN(LOG_APP,
            "[RustDesk] strategy=auto rejected fail-closed; NAT/fallback capability is unavailable");
        return -42;
    }
    if (connectionStrategy != "force_relay" &&
        connectionStrategy != "direct_ip") {
        const std::string message =
            "RDERR|stage=strategy|code=invalid_strategy|attempt=" +
            std::to_string(sessionId) + "|detail=invalid connection strategy";
        impl_->setState(ConnectionState::ERROR, message);
        OH_LOG_ERROR(LOG_APP, "[RustDesk] invalid connection strategy rejected");
        return -43;
    }
    if ((connectionStrategy == "direct_ip") != cfg.rdDirectIp) {
        const std::string message =
            "RDERR|stage=strategy|code=strategy_mode_mismatch|attempt=" +
            std::to_string(sessionId) + "|detail=connection strategy and direct mode disagree";
        impl_->setState(ConnectionState::ERROR, message);
        OH_LOG_ERROR(LOG_APP, "[RustDesk] connection strategy/direct mode mismatch rejected");
        return -44;
    }

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
        const std::string logHost = SafeLog::HashForLog(cfg.host);
        const int effectivePort = cfg.port > 0 ? cfg.port :
            (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT);
        OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] Connecting endpointId=%{public}s port=%{public}d",
                    logHost.c_str(), effectivePort);
        const std::string ffiPeerId = cfg.rdDirectIp && !cfg.host.empty()
            ? cfg.host
            : (cfg.customHostname.empty() ? cfg.username : cfg.customHostname);
        const std::string logPeer = SafeLog::HashForLog(ffiPeerId);
        const char* serverKeyMode = cfg.rdServerKeyMode == 2 ? "shared" :
            (cfg.rdServerKeyMode == 1 ? "public" : "auto");
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Request peerId=%{public}s strategy=%{public}s serverKeyMode=%{public}s proToken=%{public}s relayFallbackPort=%{public}d",
                    logPeer.c_str(), connectionStrategy.c_str(), serverKeyMode,
                    cfg.rdAccessToken.empty() ? "absent" : "present", cfg.rdRelayPort);

        RustDeskBridge::Impl* impl = impl_.get();
        const std::shared_ptr<RustDeskBridge::Impl> implKeepAlive = impl_;
        const uint64_t callbackGeneration =
            impl_->cursorGeneration.load(std::memory_order_acquire);
        const uint64_t callbackOwnerToken =
            impl_->ownerToken.load(std::memory_order_acquire);
        const uint64_t callbackAdmissionEpoch =
            impl_->ffiAdmissionEpoch.load(std::memory_order_acquire);
        auto connectDone = std::make_shared<RustDeskCompletionFence>(false);
        std::thread connectThread;
        try {
            connectThread = std::thread([impl, implKeepAlive, cfg, ffiPeerId, logHost, serial,
                                   callbackGeneration, callbackOwnerToken,
                                   callbackAdmissionEpoch, sessionId,
                                   continuityAttemptToken,
                                   continuityReconnect, continuityFenceValid,
                                   connectDone]() {
            struct ConnectDoneFence {
                std::shared_ptr<RustDeskCompletionFence> value;
                ~ConnectDoneFence() {
                    value->store(true, std::memory_order_release);
                }
            } done {connectDone};
            try {
                if (continuityReconnect && !continuityFenceValid()) {
                    return;
                }
            auto callbackContext = std::make_unique<RustDeskFfiCallbackContext>();
            callbackContext->impl = impl;
            callbackContext->implKeepAlive = implKeepAlive;
            callbackContext->generation = callbackGeneration;
            callbackContext->ownerToken = callbackOwnerToken;
            callbackContext->admissionEpoch = callbackAdmissionEpoch;
            RustDeskFfiCallbackContext* callbackUserData = callbackContext.get();
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                if (serial != impl->connectSerial.load(std::memory_order_acquire) ||
                    callbackGeneration != impl->cursorGeneration.load(std::memory_order_acquire) ||
                    callbackOwnerToken == 0 ||
                    callbackOwnerToken != impl->ownerToken.load(std::memory_order_acquire) ||
                    callbackAdmissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
                    impl->disconnectRequested.load(std::memory_order_acquire) ||
                    impl->ffiCallbackContext != nullptr) {
                    return;
                }
                impl->ffiCallbackContext = std::move(callbackContext);
            }
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
            ffiCfg.key_mode = cfg.rdServerKeyMode;
            ffiCfg.token    = cfg.rdAccessToken.c_str();
            ffiCfg.connection_id = sessionId;
            ffiCfg.relay_fallback_port = cfg.rdRelayPort;
            // T-209: 直连模式映射
            ffiCfg.direct_connection = false;
            if (cfg.rdDirectIp && !cfg.host.empty()) {
                // 仅当 rdDirectIp=true 且 host 非空时才走直连路径
                // host 此时是对端 IP 地址 (ArkTS 侧根据 per-host 配置填入)
                ffiCfg.direct_connection = true;
                OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] direct_connection=true peerId=%{public}s port=%{public}d",
                    logHost.c_str(), ffiCfg.port);
            }
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] ffiCfg codec=%{public}d(%{public}s) quality=%{public}d privacy=%{public}s audio=%{public}s authMode=%{public}d size=%{public}dx%{public}d profile=%{public}d fps=%{public}d relayFallbackPort=%{public}d",
                ffiCfg.codec,
                rdCodecName(static_cast<int>(cfg.codec)),
                ffiCfg.imageQuality,
                ffiCfg.privacyMode ? "on" : "off",
                ffiCfg.audioEnabled ? "on" : "off",
                ffiCfg.auth_mode,
                ffiCfg.width,
                ffiCfg.height,
                ffiCfg.profile,
                ffiCfg.fps,
                ffiCfg.relay_fallback_port);

            if (continuityReconnect && !continuityFenceValid()) {
                return;
            }
            bool networkCallClaimed = !continuityReconnect;
            if (continuityReconnect) {
                std::lock_guard<std::mutex> admissionLock(impl->continuityAdmissionMutex);
                networkCallClaimed =
                    impl->continuityNetworkClaimToken.load(std::memory_order_acquire) ==
                        continuityAttemptToken &&
                    impl->continuityNetworkCallActive.load(std::memory_order_acquire) &&
                    continuityFenceValid();
            }
            if (!networkCallClaimed) {
                return;
            }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
            if (continuityReconnect) {
                std::function<void(int)> claimHook;
                {
                    std::lock_guard<std::mutex> lock(impl->continuityAdmissionMutex);
                    claimHook = impl->continuityAttemptStageHook;
                }
                if (claimHook) {
                    claimHook(3); // final claim, immediately before FFI call
                }
                if (!continuityFenceValid()) {
                    impl->continuityNetworkCallCancelled.store(true,
                                                               std::memory_order_release);
                }
            }
#endif
            void* ffiHandle = rustdesk_connect_v4(
                &ffiCfg, onFfiFrame, onFfiAudio, onFfiCursor, onFfiDisconnect,
                onFfiDisplay, onFfiAuth, onFfiTransportEvent, callbackUserData);
            if (continuityReconnect) {
                impl->continuityNetworkCallActive.store(false, std::memory_order_release);
            }
            bool discardHandle = serial != impl->connectSerial.load() ||
                impl->disconnectRequested.load() || impl->ffiStreamEnded.load() ||
                (continuityReconnect && !continuityFenceValid());
            if (!discardHandle) {
                std::lock_guard<std::mutex> lock(impl->mutex);
                discardHandle = serial != impl->connectSerial.load() ||
                    impl->disconnectRequested.load() || impl->ffiStreamEnded.load();
                if (!discardHandle && continuityReconnect && !continuityFenceValid()) {
                    discardHandle = true;
                }
                if (!discardHandle && ffiHandle != nullptr &&
                    !impl->displayControl.attachHandle(ffiHandle)) {
                    discardHandle = true;
                } else if (!discardHandle && ffiHandle != nullptr) {
                    impl->ffiHandleGeneration.store(
                        callbackGeneration, std::memory_order_release);
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
                const bool continuityAttempt = impl->continuityAttemptActive.exchange(
                    false, std::memory_order_acq_rel);
                // A user disconnect or a newer connect invalidates this
                // worker's result.  Cancellation is not an authentication or
                // transport failure and must not overwrite the already
                // published DISCONNECTED/next-generation state with ERROR.
                const bool teardownWon =
                    impl->disconnectRequested.load(std::memory_order_acquire) ||
                    serial != impl->connectSerial.load(std::memory_order_acquire) ||
                    (continuityReconnect && !continuityFenceValid());
                char errBuf[512] = {0};
                rustdesk_last_error(errBuf, sizeof(errBuf));
                OH_LOG_ERROR(LOG_APP, "[RustDesk-FFI] connection failed: %{public}s", errBuf);
                std::string errMsg = errBuf[0] != '\0'
                    ? std::string("FFI connection failed: ") + errBuf
                    : "FFI connection failed - check host/port and network";
                if (continuityAttempt) {
                    impl->continuityExecutor->recordAttemptResult(false, rdSteadyNowMs());
                } else if (!teardownWon) {
                    impl->setState(ConnectionState::ERROR, errMsg);
                }
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
                if (impl->displayControl.ownsHandle(ffiHandle) &&
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
            const bool continuityAttempt = impl->continuityAttemptActive.exchange(
                false, std::memory_order_acq_rel);
            if (continuityAttempt) {
                    impl->continuityExecutor->recordAttemptResult(true, rdSteadyNowMs());
            }
            if (connectedCallback) {
                connectedCallback(ConnectionState::CONNECTED, connectedMessage);
            }
                OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Connected handle=%{public}p", ffiHandle);
            } catch (const std::exception& ex) {
                // An exception escaping a std::thread entry terminates the
                // process.  Keep the callback context owned by Impl so the
                // normal disconnect path can still fence and reclaim it.
                impl->continuityNetworkCallActive.store(false, std::memory_order_release);
                impl->continuityAttemptActive.store(false, std::memory_order_release);
                impl->continuityReconnectPending.store(false, std::memory_order_release);
                if (continuityReconnect) {
                    impl->continuityExecutor->recordAttemptResult(false, rdSteadyNowMs());
                } else if (!impl->disconnectRequested.load(std::memory_order_acquire) &&
                           serial == impl->connectSerial.load(std::memory_order_acquire)) {
                    impl->setState(ConnectionState::ERROR,
                        std::string("RustDesk connect worker failed: ") + ex.what());
                }
            } catch (...) {
                impl->continuityNetworkCallActive.store(false, std::memory_order_release);
                impl->continuityAttemptActive.store(false, std::memory_order_release);
                impl->continuityReconnectPending.store(false, std::memory_order_release);
                if (continuityReconnect) {
                    impl->continuityExecutor->recordAttemptResult(false, rdSteadyNowMs());
                } else if (!impl->disconnectRequested.load(std::memory_order_acquire) &&
                           serial == impl->connectSerial.load(std::memory_order_acquire)) {
                    impl->setState(ConnectionState::ERROR,
                        "RustDesk connect worker failed");
                }
            }
            });
        } catch (const std::exception& ex) {
            impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
            impl_->continuityAttemptActive.store(false, std::memory_order_release);
            impl_->continuityReconnectPending.store(false, std::memory_order_release);
            if (!continuityReconnect) {
                impl_->setState(ConnectionState::ERROR,
                    std::string("RustDesk connect worker start failed: ") + ex.what());
            }
            return -11;
        } catch (...) {
            impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
            impl_->continuityAttemptActive.store(false, std::memory_order_release);
            impl_->continuityReconnectPending.store(false, std::memory_order_release);
            if (!continuityReconnect) {
                impl_->setState(ConnectionState::ERROR,
                    "RustDesk connect worker start failed");
            }
            return -11;
        }
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->ffiConnectThread = std::move(connectThread);
            impl_->ffiConnectDone = std::move(connectDone);
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
        impl_->continuityQuiesce.reopen();
        impl_->inputForwardReady.store(true, std::memory_order_release);
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

void RustDeskBridge::disconnectImpl(bool cancelContinuity) {
    const uint64_t sessionId = impl_->sessionId.load(std::memory_order_acquire);
    const uint64_t disconnectGeneration =
        impl_->cursorGeneration.load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        // Invalidate the callback stream before any blocking teardown. A
        // callback already in the sink is allowed to drain, but no stale S1
        // callback can commit a first frame or enqueue a continuity action.
        impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
        impl_->disconnectRequested.store(true, std::memory_order_release);
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
        impl_->inputForwardReady.store(false, std::memory_order_release);
        impl_->continuityAttemptToken.store(0, std::memory_order_release);
        impl_->continuityNetworkClaimToken.store(0, std::memory_order_release);
        impl_->continuityNetworkCallActive.store(false, std::memory_order_release);
        impl_->continuityNetworkCallCancelled.store(true, std::memory_order_release);
        impl_->firstFrameClaimToken.store(0, std::memory_order_release);
        impl_->firstFrameCommittedToken.store(0, std::memory_order_release);
    }
    if (cancelContinuity) {
    impl_->continuityExecutor->cancel();
    }
    applyContinuityFastQuiesce();
#ifdef RUSTDESK_USE_REAL_CORE
    void* ffiHandle = nullptr;
#endif
    {
        auto displayLease = impl_->displayControl.acquireDisplayLease();
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->cursorStore.setVisibleIfGeneration(disconnectGeneration, false);
        displayLease.reset();
#ifdef RUSTDESK_USE_REAL_CORE
        // Detach while the display lifecycle boundary is exclusive. Existing
        // handle leases have drained, and no later FFI call can acquire this
        // pointer. rustdesk_disconnect() runs after releasing the boundary
        // because it joins the stream that emits onFfiDisconnect().
        ffiHandle = impl_->displayControl.detachHandle();
        impl_->ffiHandleGeneration.store(0, std::memory_order_release);
#endif
    }
    ++impl_->connectSerial;
    if (impl_->ipcFd >= 0) {
        shutdown(impl_->ipcFd, SHUT_RDWR);
        close(impl_->ipcFd);
        impl_->ipcFd = -1;
    }
#ifdef RUSTDESK_USE_REAL_CORE
    // FFI 句柄在登录完成前尚未返回，先取消等待中的连接尝试，避免点击返回后
    // 审批等待线程继续占用中继连接。
    rustdesk_cancel_pending_connect_for_session(sessionId);
    std::thread ffiConnectThread;
    std::shared_ptr<RustDeskCompletionFence> ffiConnectDone;
    std::vector<std::thread> ffiCleanupThreads;
    std::vector<std::shared_ptr<RustDeskCompletionFence>> ffiCleanupDone;
    std::thread continuityQuiesceThread;
    std::shared_ptr<RustDeskCompletionFence> continuityQuiesceDone;
    bool deferredThreadJoin = false;
    auto deferFfiThreadJoin = [this](std::thread worker,
                                     std::shared_ptr<RustDeskCompletionFence> done) {
        auto keepAlive = impl_;
        impl_->ffiDeferredJoinCount.fetch_add(1, std::memory_order_acq_rel);
        rustDeskThreadJoiner().enqueue(
            std::move(worker), keepAlive, [keepAlive]() {
                const uint32_t remaining = keepAlive->ffiDeferredJoinCount.fetch_sub(
                    1, std::memory_order_acq_rel) - 1;
                if (remaining == 0) {
                    std::lock_guard<std::mutex> lock(keepAlive->mutex);
                    keepAlive->ffiCallbackContext.reset();
                    keepAlive->continuityQuiesce.markDeferredDestroyComplete();
                }
            }, std::move(done));
    };
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiConnectThread = std::move(impl_->ffiConnectThread);
        ffiConnectDone = std::move(impl_->ffiConnectDone);
        ffiCleanupThreads = std::move(impl_->ffiCleanupThreads);
        ffiCleanupDone = std::move(impl_->ffiCleanupDone);
        continuityQuiesceThread = std::move(impl_->continuityQuiesceThread);
        continuityQuiesceDone = impl_->continuityQuiesceDoneFence;
    }
    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        // applyContinuityFastQuiesce() normally detached and scheduled the
        // handle already. Keep this fallback for a handle attached between
        // the two lifecycle barriers, but never call the Rust destructor
        // inline from an FFI callback thread.
        scheduleFfiHandleCleanup(impl_, ffiHandle);
    }
    drainDeferredFfiHandles(impl_.get());
    if (ffiConnectThread.joinable()) {
        // A connect/relay worker can still be inside a bounded socket wait
        // after cancellation.  Keep the UI/transport-loss fast path bounded
        // by handing every join to the single owner; self-join is therefore
        // safe as well, and no callback context is reclaimed before join.
        deferredThreadJoin = true;
        deferFfiThreadJoin(std::move(ffiConnectThread), std::move(ffiConnectDone));
    }
    for (size_t index = 0; index < ffiCleanupThreads.size(); ++index) {
        std::thread& cleanupThread = ffiCleanupThreads[index];
        if (!cleanupThread.joinable()) {
            continue;
        }
        deferredThreadJoin = true;
        std::shared_ptr<RustDeskCompletionFence> done = index < ffiCleanupDone.size()
            ? std::move(ffiCleanupDone[index]) : nullptr;
        deferFfiThreadJoin(std::move(cleanupThread), std::move(done));
    }
    if (continuityQuiesceThread.joinable()) {
        deferredThreadJoin = true;
        deferFfiThreadJoin(std::move(continuityQuiesceThread),
                           std::move(continuityQuiesceDone));
    }
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        // All FFI callbacks and cleanup workers have quiesced before the
        // generation context is reclaimed. A subsequent connect allocates a
        // fresh context with a fresh generation.
        if (!deferredThreadJoin &&
            impl_->ffiDeferredJoinCount.load(std::memory_order_acquire) == 0) {
            impl_->ffiCallbackContext.reset();
            impl_->continuityQuiesce.markDeferredDestroyComplete();
        }
    }
#endif
    // No-real-core builds have no RustDesk deferred joiner. The owned
    // quiesce worker is still never detached; it is joined only after the
    // admission/gate fast path has returned.
#ifndef RUSTDESK_USE_REAL_CORE
    std::thread continuityQuiesceThread;
    std::shared_ptr<RustDeskCompletionFence> continuityQuiesceDone;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        continuityQuiesceThread = std::move(impl_->continuityQuiesceThread);
        continuityQuiesceDone = impl_->continuityQuiesceDoneFence;
    }
    if (continuityQuiesceThread.joinable()) {
        if (continuityQuiesceThread.get_id() == std::this_thread::get_id()) {
            // Reentrant audio teardown can arrive on the quiesce worker. Keep
            // the worker alive in the owned joiner instead of self-joining or
            // destroying a still-joinable std::thread.
            rustDeskThreadJoiner().enqueue(
                std::move(continuityQuiesceThread), impl_, {},
                std::move(continuityQuiesceDone));
        } else if (impl_->continuityQuiesceDone.load(std::memory_order_acquire)) {
            continuityQuiesceThread.join();
        } else {
            rustDeskThreadJoiner().enqueue(
                std::move(continuityQuiesceThread), impl_, {},
                std::move(continuityQuiesceDone));
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

void RustDeskBridge::disconnect() {
    // Public/explicit disconnect always cancels a pending continuity action,
    // even when the action already owns an in-flight attempt.
    disconnectImpl(true);
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
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.inputAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiKeySendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendKey #%{public}llu sc=%{public}u pressed=%{public}s",
                static_cast<unsigned long long>(index),
                scancode,
                pressed ? "yes" : "no");
        }
        rustdesk_send_key(handleLease.get(), scancode, pressed);
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
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.inputAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
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
        rustdesk_send_mouse(handleLease.get(), x, y, ffiButton, pressed);
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
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.inputAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiWheelSendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendWheel #%{public}llu x=%{public}d y=%{public}d delta=%{public}d",
                static_cast<unsigned long long>(index),
                x,
                y,
                delta);
        }
        rustdesk_send_mouse_wheel(handleLease.get(), x, y, delta);
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
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.inputAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiTextSendCount;
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] sendText #%{public}llu len=%{public}zu",
            static_cast<unsigned long long>(index),
            text.size());
        rustdesk_send_text(handleLease.get(), text.c_str());
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
    if (!impl_->continuityQuiesce.fileAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return -1;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiFileSendCount;
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] sendFileData #%{public}llu pathId=%{public}s len=%{public}u",
            static_cast<unsigned long long>(index),
            SafeLog::HashForLog(remotePath).c_str(),
            len);
        const uint64_t transferId = impl_->nextTransferId.fetch_add(1);
        impl_->transferStatus.markRustDeskProgress(transferId, 0, len);
        return rustdesk_send_file(
            handleLease.get(), transferId, remotePath.c_str(), data, len) == 0
            ? static_cast<int>(transferId) : -1;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] sendFileData: FFI mode not available (mode=%{public}d)", static_cast<int>(mode_));
    return -1;
}

SessionTransferStatus RustDeskBridge::getSessionTransferStatus() {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        RustDeskFfiTransferStatus ffi {};
        if (rustdesk_get_transfer_status(handleLease.get(), &ffi)) {
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
    if (!impl_->continuityQuiesce.clipboardAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    if (!impl_->inputForwardReady.load(std::memory_order_acquire)) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        rustdesk_send_clipboard(handleLease.get(), data, len);
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] sendClipboardData: FFI mode not available");
}

std::string RustDeskBridge::getClipboardText() {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.clipboardAllowed() ||
        !impl_->continuityQuiesce.controlAllowed()) return "";
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        const size_t length = rustdesk_get_clipboard(handleLease.get(), nullptr, 0);
        if (length == 0 || length > 65536) return "";
        std::vector<unsigned char> buffer(length);
        const size_t copied =
            rustdesk_get_clipboard(handleLease.get(), buffer.data(), buffer.size());
        if (copied != length) return "";
        return std::string(reinterpret_cast<const char*>(buffer.data()), buffer.size());
    }
#endif
    return "";
}

bool RustDeskBridge::isClipboardReceiveReady() {
#ifdef RUSTDESK_USE_REAL_CORE
    return mode_ == RustDeskMode::FFI &&
        impl_->inputForwardReady.load(std::memory_order_acquire) &&
        impl_->continuityQuiesce.clipboardAllowed() &&
        impl_->continuityQuiesce.controlAllowed() &&
        impl_->displayControl.hasHandle();
#else
    return false;
#endif
}

void RustDeskBridge::requestFrameRefresh() {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        const bool ok = rustdesk_request_frame_refresh(handleLease.get());
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] requestFrameRefresh sent=%{public}s", ok ? "true" : "false");
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] requestFrameRefresh skipped: mode=%{public}d no ffi handle",
                static_cast<int>(mode_));
}

void RustDeskBridge::reportVideoPressure(int level) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_->inputForwardReady.load(std::memory_order_acquire) ||
        !impl_->continuityQuiesce.controlAllowed()) return;
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        rustdesk_report_video_pressure(handleLease.get(), level);
        return;
    }
#else
    (void)level;
#endif
}

bool RustDeskBridge::reportVideoPressureForSession(uint64_t sessionId,
                                                   uint64_t generation,
                                                   uint64_t ownerToken,
                                                   int level) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ != RustDeskMode::FFI || sessionId == 0 || generation == 0 ||
        ownerToken == 0) {
        return false;
    }
    const Render::DecoderSessionIdentity owner {sessionId, generation, ownerToken};
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        return false;
    }
    // Keep identity validation and handle lookup inside the same lifecycle
    // boundary used by reconnect/teardown. A caller that was valid one
    // instruction earlier must not report pressure to a new handle. Do not
    // hold impl_->mutex or the display-switch coordinator while entering FFI:
    // the Rust callback may synchronously dispatch another frame or disconnect.
    if (impl_->sessionId.load(std::memory_order_acquire) != sessionId ||
        impl_->cursorGeneration.load(std::memory_order_acquire) != generation ||
        impl_->ownerToken.load(std::memory_order_acquire) != ownerToken ||
        impl_->disconnectRequested.load(std::memory_order_acquire) ||
        impl_->ffiStreamEnded.load(std::memory_order_acquire) ||
        !impl_->inputForwardReady.load(std::memory_order_acquire)) {
        return false;
    }
    auto handleLease = impl_->displayControl.acquireHandle();
    if (!handleLease) {
        return false;
    }
    if (impl_->sessionId.load(std::memory_order_acquire) != sessionId ||
        impl_->cursorGeneration.load(std::memory_order_acquire) != generation ||
        impl_->ownerToken.load(std::memory_order_acquire) != ownerToken ||
        impl_->disconnectRequested.load(std::memory_order_acquire) ||
        impl_->ffiStreamEnded.load(std::memory_order_acquire) ||
        !impl_->inputForwardReady.load(std::memory_order_acquire)) {
        return false;
    }
    rustdesk_report_video_pressure(handleLease.get(), level);
    return true;
#else
    (void)sessionId;
    (void)generation;
    (void)ownerToken;
    (void)level;
    return false;
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

#ifdef RDP_NATIVE_CALLBACK_TESTING
bool RustDeskBridge::InvokeVideoCallbackForTesting(
    const uint8_t* data, size_t size, int width, int height, int codec,
    uint64_t timestamp, bool isKeyFrame, int display, uint64_t generation,
    uint64_t ownerToken) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_ || !data || size == 0) {
        return false;
    }
    const uint64_t before = impl_->callbackVideoFrames.load(std::memory_order_acquire);
    RustDeskFfiCallbackContext context;
    context.impl = impl_.get();
    context.generation = generation;
    context.ownerToken = ownerToken;
    context.admissionEpoch = impl_->ffiAdmissionEpoch.load(std::memory_order_acquire);
    RustDeskFfiVideoFrameV2 frame {
        data, size, width, height, codec, timestamp, isKeyFrame, display,
        kRustDeskVideoFrameAbiVersion, sizeof(RustDeskFfiVideoFrameV2),
    };
    onFfiFrame(&frame, &context);
    return impl_->callbackVideoFrames.load(std::memory_order_acquire) != before;
#else
    (void)data;
    (void)size;
    (void)width;
    (void)height;
    (void)codec;
    (void)timestamp;
    (void)isKeyFrame;
    (void)display;
    (void)generation;
    (void)ownerToken;
    return false;
#endif
}

bool RustDeskBridge::InvokeTransportCallbackForTesting(
    int state, const char* errorClass, uint64_t networkGeneration,
    bool userInitiated, uint64_t generation, uint64_t ownerToken) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_) {
        return false;
    }
    const uint64_t before = impl_->continuityQuiesce.snapshot().quiesceCount;
    RustDeskFfiCallbackContext context;
    context.impl = impl_.get();
    context.generation = generation;
    context.ownerToken = ownerToken;
    context.admissionEpoch = impl_->ffiAdmissionEpoch.load(std::memory_order_acquire);
    RustDeskFfiTransportEvent event {
        state, errorClass, networkGeneration, userInitiated,
    };
    onFfiTransportEvent(&event, &context);
    return impl_->continuityQuiesce.snapshot().quiesceCount > before;
#else
    (void)state;
    (void)errorClass;
    (void)networkGeneration;
    (void)userInitiated;
    (void)generation;
    (void)ownerToken;
    return false;
#endif
}

void RustDeskBridge::SetAttemptDequeuedHookForTesting(std::function<void()> hook) {
    impl_->continuityExecutor->setAttemptDequeuedHookForTesting(std::move(hook));
}

void RustDeskBridge::SetFirstFrameClaimHookForTesting(std::function<void()> hook) {
    std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
    impl_->firstFrameClaimHook = std::move(hook);
}

void RustDeskBridge::SetContinuityAttemptStageHookForTesting(
    std::function<void(int)> hook) {
    std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
    impl_->continuityAttemptStageHook = std::move(hook);
}

void RustDeskBridge::SetContinuityConnectResultHookForTesting(
    std::function<int(uint64_t, uint64_t)> hook) {
    std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
    impl_->continuityConnectResultHook = std::move(hook);
}

void RustDeskBridge::SetContinuityConfigForTesting(const ConnectionConfig& config) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->config = config;
}

uint32_t RustDeskBridge::continuityConnectCallCountForTesting() const {
    return impl_->continuityConnectCallCount.load(std::memory_order_acquire);
}

void RustDeskBridge::ArmFirstGenerationFrameForTesting() {
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
        impl_->disconnectRequested.store(false, std::memory_order_release);
        impl_->ffiStreamEnded.store(false, std::memory_order_release);
        impl_->firstFrameClaimToken.store(0, std::memory_order_release);
        impl_->firstFrameCommittedToken.store(0, std::memory_order_release);
    }
    impl_->continuityQuiesce.closeForTransportLoss();
    impl_->continuityQuiesce.reopenGenerationAdmission();
    impl_->awaitingFirstGenerationFrame.store(true, std::memory_order_release);
}
#endif

void RustDeskBridge::setAudioCallback(AudioDataCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->audioCallback = std::move(cb);
}
void RustDeskBridge::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stateCallback = std::move(cb);
}
void RustDeskBridge::setDisplayStateCallback(RustDeskDisplayStateCallback callback) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->displayStateCallback = std::move(callback);
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

#include "moonlight/input/MoonlightGameControllerListener.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#if defined(__OHOS__)
#include <dlfcn.h>
#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_pad.h>
#include <GameControllerKit/game_pad_event.h>
#endif

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kMaximumSdkTextBytes = 256U;

std::uint64_t stableDeviceId(const char* value) noexcept {
    // FNV-1a is used only as an in-process stable slot key. The SDK string is
    // never logged, persisted, or returned to ArkTS.
    if (value == nullptr || value[0] == '\0') {
        return 0U;
    }
    std::uint64_t hash = 1469598103934665603ULL;
    std::size_t length = 0U;
    for (const unsigned char* cursor =
             reinterpret_cast<const unsigned char*>(value);
         *cursor != 0U && length < kMaximumSdkTextBytes; ++cursor, ++length) {
        hash ^= static_cast<std::uint64_t>(*cursor);
        hash *= 1099511628211ULL;
    }
    return hash == 0U ? 1U : hash;
}

#if defined(__OHOS__)

#define REMOTEDESK_GAME_CONTROLLER_SYMBOLS(X) \
    X(OH_GameDevice_AllDeviceInfos_GetCount) \
    X(OH_GameDevice_AllDeviceInfos_GetDeviceInfo) \
    X(OH_GameDevice_DestroyAllDeviceInfos) \
    X(OH_GameDevice_DestroyDeviceInfo) \
    X(OH_GameDevice_DeviceEvent_GetChangedType) \
    X(OH_GameDevice_DeviceEvent_GetDeviceInfo) \
    X(OH_GameDevice_DeviceInfo_GetDeviceId) \
    X(OH_GameDevice_DeviceInfo_GetDeviceType) \
    X(OH_GameDevice_GetAllDeviceInfos) \
    X(OH_GameDevice_RegisterDeviceMonitor) \
    X(OH_GameDevice_UnregisterDeviceMonitor) \
    X(OH_GamePad_AxisEvent_GetAxisSourceType) \
    X(OH_GamePad_AxisEvent_GetBrakeAxisValue) \
    X(OH_GamePad_AxisEvent_GetDeviceId) \
    X(OH_GamePad_AxisEvent_GetGasAxisValue) \
    X(OH_GamePad_AxisEvent_GetHatXAxisValue) \
    X(OH_GamePad_AxisEvent_GetHatYAxisValue) \
    X(OH_GamePad_AxisEvent_GetRZAxisValue) \
    X(OH_GamePad_AxisEvent_GetXAxisValue) \
    X(OH_GamePad_AxisEvent_GetYAxisValue) \
    X(OH_GamePad_AxisEvent_GetZAxisValue) \
    X(OH_GamePad_ButtonEvent_GetButtonAction) \
    X(OH_GamePad_ButtonEvent_GetDeviceId) \
    X(OH_GamePad_LeftShoulder_RegisterButtonInputMonitor) \
    X(OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor) \
    X(OH_GamePad_RightShoulder_RegisterButtonInputMonitor) \
    X(OH_GamePad_RightShoulder_UnregisterButtonInputMonitor) \
    X(OH_GamePad_LeftTrigger_RegisterButtonInputMonitor) \
    X(OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor) \
    X(OH_GamePad_RightTrigger_RegisterButtonInputMonitor) \
    X(OH_GamePad_RightTrigger_UnregisterButtonInputMonitor) \
    X(OH_GamePad_ButtonMenu_RegisterButtonInputMonitor) \
    X(OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor) \
    X(OH_GamePad_ButtonHome_RegisterButtonInputMonitor) \
    X(OH_GamePad_ButtonHome_UnregisterButtonInputMonitor) \
    X(OH_GamePad_ButtonA_RegisterButtonInputMonitor) \
    X(OH_GamePad_ButtonA_UnregisterButtonInputMonitor) \
    X(OH_GamePad_ButtonB_RegisterButtonInputMonitor) \
    X(OH_GamePad_ButtonB_UnregisterButtonInputMonitor) \
    X(OH_GamePad_ButtonX_RegisterButtonInputMonitor) \
    X(OH_GamePad_ButtonX_UnregisterButtonInputMonitor) \
    X(OH_GamePad_ButtonY_RegisterButtonInputMonitor) \
    X(OH_GamePad_ButtonY_UnregisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor) \
    X(OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor) \
    X(OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor) \
    X(OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor) \
    X(OH_GamePad_RightThumbstick_RegisterButtonInputMonitor) \
    X(OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor) \
    X(OH_GamePad_LeftTrigger_RegisterAxisInputMonitor) \
    X(OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor) \
    X(OH_GamePad_RightTrigger_RegisterAxisInputMonitor) \
    X(OH_GamePad_RightTrigger_UnregisterAxisInputMonitor) \
    X(OH_GamePad_Dpad_RegisterAxisInputMonitor) \
    X(OH_GamePad_Dpad_UnregisterAxisInputMonitor) \
    X(OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor) \
    X(OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor) \
    X(OH_GamePad_RightThumbstick_RegisterAxisInputMonitor) \
    X(OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor)

struct GameControllerApi final {
    void* handle = nullptr;

#define REMOTEDESK_DECLARE_GAME_CONTROLLER_SYMBOL(name) \
    decltype(&::name) name = nullptr;
    REMOTEDESK_GAME_CONTROLLER_SYMBOLS(
        REMOTEDESK_DECLARE_GAME_CONTROLLER_SYMBOL)
#undef REMOTEDESK_DECLARE_GAME_CONTROLLER_SYMBOL

    template <typename Function>
    static bool resolve(void* library, const char* name,
                        Function& output) noexcept {
        void* symbol = dlsym(library, name);
        static_assert(sizeof(symbol) == sizeof(output),
                      "function and data pointers must share the OHOS ABI size");
        std::memcpy(&output, &symbol, sizeof(output));
        return output != nullptr;
    }

    bool load() noexcept {
        if (handle != nullptr) {
            return true;
        }
        handle = dlopen("libohgame_controller.z.so", RTLD_NOW | RTLD_LOCAL);
        if (handle == nullptr) {
            return false;
        }
        bool complete = true;
#define REMOTEDESK_RESOLVE_GAME_CONTROLLER_SYMBOL(name) \
        complete = resolve(handle, #name, name) && complete;
        REMOTEDESK_GAME_CONTROLLER_SYMBOLS(
            REMOTEDESK_RESOLVE_GAME_CONTROLLER_SYMBOL)
#undef REMOTEDESK_RESOLVE_GAME_CONTROLLER_SYMBOL
        if (!complete) {
            unload();
        }
        return complete;
    }

    void unload() noexcept {
#define REMOTEDESK_CLEAR_GAME_CONTROLLER_SYMBOL(name) name = nullptr;
        REMOTEDESK_GAME_CONTROLLER_SYMBOLS(
            REMOTEDESK_CLEAR_GAME_CONTROLLER_SYMBOL)
#undef REMOTEDESK_CLEAR_GAME_CONTROLLER_SYMBOL
        if (handle != nullptr) {
            (void)dlclose(handle);
            handle = nullptr;
        }
    }

    ~GameControllerApi() { unload(); }
};

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

std::uint64_t monotonicNowUs() noexcept {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    const auto value = std::chrono::duration_cast<std::chrono::microseconds>(now).count();
    return value <= 0 ? 1U : static_cast<std::uint64_t>(value);
}

std::string boundedText(const char* value) {
    if (value == nullptr) {
        return {};
    }
    std::size_t length = 0U;
    while (length < kMaximumSdkTextBytes && value[length] != '\0') {
        ++length;
    }
    return std::string(value, length);
}

double clampUnit(double value) noexcept {
    if (!std::isfinite(value)) {
        return 0.0;
    }
    return std::clamp(value, -1.0, 1.0);
}

double clampTrigger(double value) noexcept {
    if (!std::isfinite(value)) {
        return 0.0;
    }
    return std::clamp(value, 0.0, 1.0);
}

struct DeviceInfoCopy final {
    std::uint64_t deviceId = 0U;
    GameDevice_DeviceType type = UNKNOWN;
    std::string sdkId;
};

bool copyDeviceInfo(GameControllerApi& api,
                    const GameDevice_DeviceInfo* info,
                    DeviceInfoCopy& output) noexcept {
    if (info == nullptr) {
        return false;
    }
    char* sdkId = nullptr;
    GameDevice_DeviceType type = UNKNOWN;
    if (api.OH_GameDevice_DeviceInfo_GetDeviceId(info, &sdkId) != GAME_CONTROLLER_SUCCESS ||
        sdkId == nullptr ||
        api.OH_GameDevice_DeviceInfo_GetDeviceType(info, &type) != GAME_CONTROLLER_SUCCESS) {
        return false;
    }
    output.sdkId = boundedText(sdkId);
    output.deviceId = stableDeviceId(sdkId);
    output.type = type;
    return output.deviceId != 0U && output.type == GAME_PAD;
}

#endif // defined(__OHOS__)

} // namespace

bool applyMoonlightGameControllerButtonInput(
    MoonlightGameControllerButtonInput input, bool pressed,
    MoonlightControllerSample& sample) noexcept {
    std::uint32_t bit = 0U;
    bool dpadButton = false;
    switch (input) {
        case MoonlightGameControllerButtonInput::FaceA:
            bit = kMoonlightControllerButtonA;
            break;
        case MoonlightGameControllerButtonInput::FaceB:
            bit = kMoonlightControllerButtonB;
            break;
        case MoonlightGameControllerButtonInput::FaceX:
            bit = kMoonlightControllerButtonX;
            break;
        case MoonlightGameControllerButtonInput::FaceY:
            bit = kMoonlightControllerButtonY;
            break;
        case MoonlightGameControllerButtonInput::DpadUp:
            bit = kMoonlightControllerButtonUp;
            dpadButton = true;
            break;
        case MoonlightGameControllerButtonInput::DpadDown:
            bit = kMoonlightControllerButtonDown;
            dpadButton = true;
            break;
        case MoonlightGameControllerButtonInput::DpadLeft:
            bit = kMoonlightControllerButtonLeft;
            dpadButton = true;
            break;
        case MoonlightGameControllerButtonInput::DpadRight:
            bit = kMoonlightControllerButtonRight;
            dpadButton = true;
            break;
        case MoonlightGameControllerButtonInput::LeftShoulder:
            bit = kMoonlightControllerButtonLeftShoulder;
            break;
        case MoonlightGameControllerButtonInput::RightShoulder:
            bit = kMoonlightControllerButtonRightShoulder;
            break;
        case MoonlightGameControllerButtonInput::LeftTrigger:
            sample.leftTrigger = pressed ? 1.0 : 0.0;
            return true;
        case MoonlightGameControllerButtonInput::RightTrigger:
            sample.rightTrigger = pressed ? 1.0 : 0.0;
            return true;
        case MoonlightGameControllerButtonInput::LeftStick:
            bit = kMoonlightControllerButtonLeftStick;
            break;
        case MoonlightGameControllerButtonInput::RightStick:
            bit = kMoonlightControllerButtonRightStick;
            break;
        case MoonlightGameControllerButtonInput::Menu:
            bit = kMoonlightControllerButtonPlay;
            break;
        case MoonlightGameControllerButtonInput::Home:
            bit = kMoonlightControllerButtonSpecial;
            break;
    }
    if (pressed) {
        sample.buttonFlags |= bit;
    } else {
        sample.buttonFlags &= ~bit;
    }
    if (dpadButton) {
        sample.hasHatAxes = false;
    }
    return true;
}

struct MoonlightGameControllerListener::Impl final {
    explicit Impl(Sink& valueSink) noexcept : sink(&valueSink) {}

    Sink* sink = nullptr;
#if defined(__OHOS__)
    GameControllerApi api;
#endif
    // Serializes SDK registration/unregistration. GameControllerKit has a
    // process-global callback table, so start/stop must not interleave.
    mutable std::mutex lifecycleMutex;
    // GameControllerKit callbacks have no context and may arrive concurrently.
    // Serialize the full callback-to-sink transaction so a disconnect/reconnect
    // cannot reorder generations or source sequences at the sink boundary.
    mutable std::mutex dispatchMutex;
    mutable std::mutex mutex;
    std::atomic<bool> started {false};
    // A sink is allowed to request stop synchronously from its callback. The
    // callback lease performs the final unregister after the current callback
    // returns, instead of making stop() wait for itself.
    std::atomic<bool> stopDeferred {false};
    std::atomic<bool> registrationActive {false};
    std::uint64_t nextGeneration = 1U;
    std::unordered_map<std::uint64_t, std::uint64_t> generations;
    std::unordered_map<std::uint64_t, std::string> sdkIds;
    std::unordered_map<std::uint64_t, MoonlightControllerSample> samples;
    // Some controllers expose triggers only as buttons, while analog pads
    // produce both button-threshold and axis callbacks. Once an axis is
    // observed for a device, keep its analog value authoritative and ignore
    // the duplicate digital threshold events.
    std::unordered_set<std::uint64_t> leftTriggerAxisDevices;
    std::unordered_set<std::uint64_t> rightTriggerAxisDevices;
    std::unordered_map<std::uint64_t, std::uint64_t> sequences;
    std::unordered_map<std::uint64_t, std::uint64_t> timestamps;
    std::unordered_set<std::uint64_t> onlineDevices;
    std::uint64_t activeDeviceId = 0U;
};

#if defined(__OHOS__)
namespace {

// The SDK has process-global callback registration and no callback context.
// Keep the pointer and the in-flight count in one function-local registry so
// all callback entry points share the same teardown fence.
struct CallbackRegistry final {
    std::mutex mutex;
    std::condition_variable cv;
    MoonlightGameControllerListener::Impl* active = nullptr;
    std::shared_ptr<MoonlightGameControllerListener::Impl> activeOwner;
    std::size_t inFlight = 0U;
};

CallbackRegistry& callbackRegistry() noexcept {
    static CallbackRegistry registry;
    return registry;
}

thread_local MoonlightGameControllerListener::Impl* currentCallbackImpl = nullptr;
thread_local std::size_t currentCallbackDepth = 0U;

bool isCurrentCallback(const MoonlightGameControllerListener::Impl& impl) noexcept {
    return currentCallbackImpl == &impl && currentCallbackDepth != 0U;
}

std::shared_ptr<MoonlightGameControllerListener::Impl> acquireCallback() noexcept {
    auto& registry = callbackRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    if (registry.active == nullptr ||
        registry.activeOwner == nullptr ||
        !registry.active->started.load(std::memory_order_acquire)) {
        return {};
    }
    ++registry.inFlight;
    return registry.activeOwner;
}

bool releaseCallback(MoonlightGameControllerListener::Impl& impl) noexcept {
    auto& registry = callbackRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    if (registry.inFlight != 0U) {
        --registry.inFlight;
    }
    registry.cv.notify_all();
    return registry.inFlight == 0U &&
        impl.stopDeferred.load(std::memory_order_acquire);
}

void stopRegisteredListener(MoonlightGameControllerListener::Impl& impl) noexcept;
void finishDeferredStop(MoonlightGameControllerListener::Impl& impl) noexcept;

class SinkDispatchScope final {
  public:
    explicit SinkDispatchScope(MoonlightGameControllerListener::Impl& value) noexcept
        : impl(&value) {
        if (currentCallbackImpl == impl) {
            ++currentCallbackDepth;
        } else {
            currentCallbackImpl = impl;
            currentCallbackDepth = 1U;
        }
    }
    ~SinkDispatchScope() {
        if (currentCallbackImpl != impl || currentCallbackDepth == 0U) {
            return;
        }
        --currentCallbackDepth;
        if (currentCallbackDepth == 0U) {
            currentCallbackImpl = nullptr;
        }
    }
    SinkDispatchScope(const SinkDispatchScope&) = delete;
    SinkDispatchScope& operator=(const SinkDispatchScope&) = delete;

  private:
    MoonlightGameControllerListener::Impl* impl = nullptr;
};

void requestStopFromCallback(MoonlightGameControllerListener::Impl& impl) noexcept {
    auto& registry = callbackRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    impl.started.store(false, std::memory_order_release);
    // Keep the process-global owner claimed until the monitor callbacks have
    // actually been unregistered. A second listener must not register while
    // this deferred teardown still owns GameControllerKit's callback table.
    impl.stopDeferred.store(true, std::memory_order_release);
}

class CallbackLease final {
  public:
    explicit CallbackLease(
        std::shared_ptr<MoonlightGameControllerListener::Impl> value) noexcept
        : owner(std::move(value)), impl(owner.get()) {
        if (impl != nullptr) {
            if (currentCallbackImpl == impl) {
                ++currentCallbackDepth;
            } else {
                currentCallbackImpl = impl;
                currentCallbackDepth = 1U;
            }
        }
    }
    ~CallbackLease() {
        if (impl == nullptr) {
            return;
        }
        const bool shouldFinish = releaseCallback(*impl);
        if (currentCallbackImpl == impl && currentCallbackDepth != 0U) {
            --currentCallbackDepth;
            if (currentCallbackDepth == 0U) {
                currentCallbackImpl = nullptr;
            }
        }
        if (shouldFinish) {
            finishDeferredStop(*impl);
        }
    }
    CallbackLease(const CallbackLease&) = delete;
    CallbackLease& operator=(const CallbackLease&) = delete;
    std::shared_ptr<MoonlightGameControllerListener::Impl> owner;
    MoonlightGameControllerListener::Impl* impl = nullptr;
};

std::uint64_t ensureDevice(MoonlightGameControllerListener::Impl& impl,
                           const char* sdkId) noexcept {
    try {
        const auto id = stableDeviceId(sdkId);
        if (id == 0U) {
            return 0U;
        }
        const auto boundedId = boundedText(sdkId);
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto existing = impl.sdkIds.find(id);
        if (existing != impl.sdkIds.end() && existing->second != boundedId) {
            return 0U;
        }
        if (existing == impl.sdkIds.end()) {
            impl.sdkIds.emplace(id, boundedId);
        }
        if (!impl.onlineDevices.insert(id).second) {
            return id;
        }
        // A reconnect receives a fresh source generation. Secondary devices
        // remain online candidates without consuming Sunshine's single slot.
        const auto generation = impl.nextGeneration == 0U ? 1U : impl.nextGeneration;
        impl.nextGeneration = saturatingIncrement(generation);
        impl.generations[id] = generation;
        impl.samples[id] = {};
        impl.leftTriggerAxisDevices.erase(id);
        impl.rightTriggerAxisDevices.erase(id);
        impl.sequences[id] = 0U;
        impl.timestamps[id] = 0U;
        return id;
    } catch (...) {
        return 0U;
    }
}

std::uint64_t findOnlineDevice(MoonlightGameControllerListener::Impl& impl,
                               const char* sdkId) noexcept {
    try {
        const auto id = stableDeviceId(sdkId);
        if (id == 0U) {
            return 0U;
        }
        const auto boundedId = boundedText(sdkId);
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto existing = impl.sdkIds.find(id);
        if (existing == impl.sdkIds.end() || existing->second != boundedId ||
            impl.onlineDevices.count(id) == 0U ||
            impl.activeDeviceId != id || impl.sequences[id] == 0U) {
            // Button/axis callbacks cannot establish a device or a new
            // generation. A late event after OFFLINE must be dropped until a
            // fresh ONLINE event is observed.
            return 0U;
        }
        return id;
    } catch (...) {
        return 0U;
    }
}

void emitConnected(MoonlightGameControllerListener::Impl& impl,
                   std::uint64_t id) noexcept {
    MoonlightControllerProfile profile;
    profile.type = MoonlightControllerType::Unknown;
    profile.supportedButtonFlags = kMoonlightControllerApi23ButtonMask;
    profile.analogTriggers = true;
    std::uint64_t generation = 0U;
    std::uint64_t sequence = 0U;
    std::uint64_t timestamp = 0U;
    {
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto found = impl.generations.find(id);
        if (found == impl.generations.end() ||
            impl.onlineDevices.count(id) == 0U) {
            return;
        }
        if (impl.activeDeviceId != 0U && impl.activeDeviceId != id) {
            return;
        }
        impl.activeDeviceId = id;
        generation = found->second;
        if (impl.sequences[id] != 0U) {
            return;
        }
        sequence = 1U;
        timestamp = monotonicNowUs();
        impl.sequences[id] = sequence;
        impl.timestamps[id] = timestamp;
    }
    if (impl.sink != nullptr) {
        SinkDispatchScope dispatch(impl);
        impl.sink->onPhysicalControllerConnected(
            id, generation, sequence, timestamp, profile);
    }
}

void emitSample(MoonlightGameControllerListener::Impl& impl,
                std::uint64_t id, const MoonlightControllerSample& sample) noexcept {
    std::uint64_t generation = 0U;
    std::uint64_t sequence = 0U;
    std::uint64_t timestamp = 0U;
    {
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto found = impl.generations.find(id);
        if (found == impl.generations.end()) {
            return;
        }
        generation = found->second;
        if (impl.sequences[id] == 0U) {
            impl.sequences[id] = 1U;
        }
        sequence = saturatingIncrement(impl.sequences[id]);
        impl.sequences[id] = sequence;
        timestamp = std::max(saturatingIncrement(impl.timestamps[id]), monotonicNowUs());
        impl.timestamps[id] = timestamp;
        impl.samples[id] = sample;
    }
    if (impl.sink != nullptr) {
        SinkDispatchScope dispatch(impl);
        impl.sink->onPhysicalControllerSample(id, generation, sequence, timestamp, sample);
    }
}

void emitDisconnected(MoonlightGameControllerListener::Impl& impl,
                      std::uint64_t id) noexcept {
    std::uint64_t generation = 0U;
    std::uint64_t sequence = 0U;
    std::uint64_t timestamp = 0U;
    bool notify = false;
    {
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto found = impl.generations.find(id);
        if (found == impl.generations.end() ||
            impl.onlineDevices.erase(id) == 0U) {
            return;
        }
        if (impl.activeDeviceId != id || impl.sequences[id] == 0U) {
            impl.samples[id] = {};
            impl.sequences[id] = 0U;
            impl.timestamps[id] = 0U;
            return;
        }
        impl.activeDeviceId = 0U;
        generation = found->second;
        sequence = saturatingIncrement(impl.sequences[id]);
        impl.sequences[id] = sequence;
        timestamp = std::max(saturatingIncrement(impl.timestamps[id]), monotonicNowUs());
        impl.timestamps[id] = timestamp;
        impl.samples[id] = {};
        impl.leftTriggerAxisDevices.erase(id);
        impl.rightTriggerAxisDevices.erase(id);
        notify = true;
    }
    if (notify && impl.sink != nullptr) {
        SinkDispatchScope dispatch(impl);
        impl.sink->onPhysicalControllerDisconnected(id, generation, sequence, timestamp);
    }
    std::uint64_t candidate = 0U;
    {
        std::lock_guard<std::mutex> lock(impl.mutex);
        impl.sequences[id] = 0U;
        impl.timestamps[id] = 0U;
        if (!impl.onlineDevices.empty()) {
            candidate = *std::min_element(
                impl.onlineDevices.begin(), impl.onlineDevices.end());
        }
    }
    if (candidate != 0U &&
        impl.started.load(std::memory_order_acquire)) {
        emitConnected(impl, candidate);
    }
}

void buttonCallback(const GamePad_ButtonEvent* event,
                    MoonlightGameControllerButtonInput input) {
    CallbackLease lease(acquireCallback());
    if (lease.impl == nullptr || event == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> dispatchLock(lease.impl->dispatchMutex);
    char* sdkId = nullptr;
    GamePad_Button_ActionType action = UP;
    auto& api = lease.impl->api;
    if (api.OH_GamePad_ButtonEvent_GetDeviceId(event, &sdkId) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_ButtonEvent_GetButtonAction(event, &action) != GAME_CONTROLLER_SUCCESS) {
        return;
    }
    const auto id = findOnlineDevice(*lease.impl, sdkId);
    if (id == 0U) {
        return;
    }
    emitConnected(*lease.impl, id);
    MoonlightControllerSample copy;
    {
        std::lock_guard<std::mutex> lock(lease.impl->mutex);
        auto& sample = lease.impl->samples[id];
        const bool analogTriggerAuthoritative =
            (input == MoonlightGameControllerButtonInput::LeftTrigger &&
             lease.impl->leftTriggerAxisDevices.count(id) != 0U) ||
            (input == MoonlightGameControllerButtonInput::RightTrigger &&
             lease.impl->rightTriggerAxisDevices.count(id) != 0U);
        if (!analogTriggerAuthoritative) {
            (void)applyMoonlightGameControllerButtonInput(
                input, action == DOWN, sample);
        }
        copy = sample;
    }
    emitSample(*lease.impl, id, copy);
}

#define REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(name, input) \
    void name(const GamePad_ButtonEvent* event) { \
        buttonCallback(event, MoonlightGameControllerButtonInput::input); \
    }

REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(leftShoulderCallback, LeftShoulder)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(rightShoulderCallback, RightShoulder)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(leftTriggerCallback, LeftTrigger)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(rightTriggerCallback, RightTrigger)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(menuCallback, Menu)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(homeCallback, Home)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(faceACallback, FaceA)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(faceBCallback, FaceB)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(faceXCallback, FaceX)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(faceYCallback, FaceY)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(dpadLeftCallback, DpadLeft)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(dpadRightCallback, DpadRight)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(dpadUpCallback, DpadUp)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(dpadDownCallback, DpadDown)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(leftStickCallback, LeftStick)
REMOTEDESK_GAMEPAD_BUTTON_CALLBACK(rightStickCallback, RightStick)

#undef REMOTEDESK_GAMEPAD_BUTTON_CALLBACK

void axisCallback(const GamePad_AxisEvent* event) {
    CallbackLease lease(acquireCallback());
    if (lease.impl == nullptr || event == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> dispatchLock(lease.impl->dispatchMutex);
    char* sdkId = nullptr;
    GamePad_AxisSourceType source = DPAD;
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
    double rz = 0.0;
    double hatX = 0.0;
    double hatY = 0.0;
    double brake = 0.0;
    double gas = 0.0;
    auto& api = lease.impl->api;
    if (api.OH_GamePad_AxisEvent_GetDeviceId(event, &sdkId) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetAxisSourceType(event, &source) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetXAxisValue(event, &x) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetYAxisValue(event, &y) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetZAxisValue(event, &z) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetRZAxisValue(event, &rz) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetHatXAxisValue(event, &hatX) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetHatYAxisValue(event, &hatY) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetBrakeAxisValue(event, &brake) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GamePad_AxisEvent_GetGasAxisValue(event, &gas) != GAME_CONTROLLER_SUCCESS) {
        return;
    }
    const auto id = findOnlineDevice(*lease.impl, sdkId);
    if (id == 0U) {
        return;
    }
    emitConnected(*lease.impl, id);
    MoonlightControllerSample copy;
    {
        std::lock_guard<std::mutex> lock(lease.impl->mutex);
        auto& sample = lease.impl->samples[id];
        switch (source) {
            case DPAD:
                sample.hasHatAxes = true;
                sample.hatX = clampUnit(hatX);
                sample.hatY = clampUnit(hatY);
                break;
            case LEFT_THUMBSTICK:
                sample.leftStickX = clampUnit(x);
                sample.leftStickY = clampUnit(y);
                break;
            case RIGHT_THUMBSTICK:
                sample.rightStickX = clampUnit(x);
                sample.rightStickY = clampUnit(y);
                break;
            case LEFT_TRIGGER:
                lease.impl->leftTriggerAxisDevices.insert(id);
                sample.leftTrigger = clampTrigger(std::max(z, brake));
                break;
            case RIGHT_TRIGGER:
                lease.impl->rightTriggerAxisDevices.insert(id);
                sample.rightTrigger = clampTrigger(std::max(rz, gas));
                break;
        }
        copy = sample;
    }
    emitSample(*lease.impl, id, copy);
}

void deviceCallback(const GameDevice_DeviceEvent* event) {
    CallbackLease lease(acquireCallback());
    if (lease.impl == nullptr || event == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> dispatchLock(lease.impl->dispatchMutex);
    GameDevice_StatusChangedType status = OFFLINE;
    GameDevice_DeviceInfo* info = nullptr;
    auto& api = lease.impl->api;
    if (api.OH_GameDevice_DeviceEvent_GetChangedType(event, &status) != GAME_CONTROLLER_SUCCESS ||
        api.OH_GameDevice_DeviceEvent_GetDeviceInfo(event, &info) != GAME_CONTROLLER_SUCCESS ||
        info == nullptr) {
        return;
    }
    DeviceInfoCopy copy;
    const bool valid = copyDeviceInfo(api, info, copy);
    (void)api.OH_GameDevice_DestroyDeviceInfo(&info);
    if (!valid) {
        return;
    }
    if (status == ONLINE) {
        const auto id = ensureDevice(*lease.impl, copy.sdkId.c_str());
        if (id != 0U) {
            emitConnected(*lease.impl, id);
        }
    } else if (status == OFFLINE) {
        emitDisconnected(*lease.impl, copy.deviceId);
    }
}

struct ButtonMonitorRegistration final {
    GameController_ErrorCode (*registerMonitor)(GamePad_ButtonInputMonitorCallback);
    GameController_ErrorCode (*unregisterMonitor)();
    GamePad_ButtonInputMonitorCallback callback;
};

struct AxisMonitorRegistration final {
    GameController_ErrorCode (*registerMonitor)(GamePad_AxisInputMonitorCallback);
    GameController_ErrorCode (*unregisterMonitor)();
};

std::array<ButtonMonitorRegistration, 14U> buttonMonitors(GameControllerApi& api) {
    return {{
        {api.OH_GamePad_LeftShoulder_RegisterButtonInputMonitor,
         api.OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor,
         leftShoulderCallback},
        {api.OH_GamePad_RightShoulder_RegisterButtonInputMonitor,
         api.OH_GamePad_RightShoulder_UnregisterButtonInputMonitor,
         rightShoulderCallback},
        {api.OH_GamePad_LeftTrigger_RegisterButtonInputMonitor,
         api.OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor,
         leftTriggerCallback},
        {api.OH_GamePad_RightTrigger_RegisterButtonInputMonitor,
         api.OH_GamePad_RightTrigger_UnregisterButtonInputMonitor,
         rightTriggerCallback},
        {api.OH_GamePad_ButtonMenu_RegisterButtonInputMonitor,
         api.OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor,
         menuCallback},
        {api.OH_GamePad_ButtonHome_RegisterButtonInputMonitor,
         api.OH_GamePad_ButtonHome_UnregisterButtonInputMonitor,
         homeCallback},
        {api.OH_GamePad_ButtonA_RegisterButtonInputMonitor,
         api.OH_GamePad_ButtonA_UnregisterButtonInputMonitor,
         faceACallback},
        {api.OH_GamePad_ButtonB_RegisterButtonInputMonitor,
         api.OH_GamePad_ButtonB_UnregisterButtonInputMonitor,
         faceBCallback},
        {api.OH_GamePad_ButtonX_RegisterButtonInputMonitor,
         api.OH_GamePad_ButtonX_UnregisterButtonInputMonitor,
         faceXCallback},
        {api.OH_GamePad_ButtonY_RegisterButtonInputMonitor,
         api.OH_GamePad_ButtonY_UnregisterButtonInputMonitor,
         faceYCallback},
        {api.OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor,
         api.OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor,
         dpadLeftCallback},
        {api.OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor,
         api.OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor,
         dpadRightCallback},
        {api.OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor,
         api.OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor,
         dpadUpCallback},
        {api.OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor,
         api.OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor,
         dpadDownCallback},
    }};
}

std::array<ButtonMonitorRegistration, 2U> thumbstickButtonMonitors(
    GameControllerApi& api) {
    return {{
        {api.OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor,
         api.OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor,
         leftStickCallback},
        {api.OH_GamePad_RightThumbstick_RegisterButtonInputMonitor,
         api.OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor,
         rightStickCallback},
    }};
}

std::array<AxisMonitorRegistration, 5U> axisMonitors(GameControllerApi& api) {
    return {{
        {api.OH_GamePad_LeftTrigger_RegisterAxisInputMonitor,
         api.OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor},
        {api.OH_GamePad_RightTrigger_RegisterAxisInputMonitor,
         api.OH_GamePad_RightTrigger_UnregisterAxisInputMonitor},
        {api.OH_GamePad_Dpad_RegisterAxisInputMonitor,
         api.OH_GamePad_Dpad_UnregisterAxisInputMonitor},
        {api.OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor,
         api.OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor},
        {api.OH_GamePad_RightThumbstick_RegisterAxisInputMonitor,
         api.OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor},
    }};
}

template <std::size_t N>
bool registerButtonMonitors(
    const std::array<ButtonMonitorRegistration, N>& monitors,
    std::size_t& registered) noexcept {
    for (const auto& monitor : monitors) {
        if (monitor.registerMonitor(monitor.callback) != GAME_CONTROLLER_SUCCESS) {
            return false;
        }
        ++registered;
    }
    return true;
}

template <std::size_t N>
bool registerAxisMonitors(
    const std::array<AxisMonitorRegistration, N>& monitors,
    std::size_t& registered) noexcept {
    for (const auto& monitor : monitors) {
        if (monitor.registerMonitor(axisCallback) != GAME_CONTROLLER_SUCCESS) {
            return false;
        }
        ++registered;
    }
    return true;
}

template <typename Registration, std::size_t N>
void unregisterMonitors(const std::array<Registration, N>& monitors,
                        std::size_t registered) noexcept {
    while (registered != 0U) {
        --registered;
        (void)monitors[registered].unregisterMonitor();
    }
}

void stopRegisteredListener(MoonlightGameControllerListener::Impl& impl) noexcept {
    impl.stopDeferred.store(false, std::memory_order_release);
    auto& registry = callbackRegistry();
    {
        std::unique_lock<std::mutex> lock(registry.mutex);
        impl.started.store(false, std::memory_order_release);
        registry.cv.wait(lock, [&]() { return registry.inFlight == 0U; });
    }
    if (impl.registrationActive.exchange(false, std::memory_order_acq_rel)) {
        const auto axes = axisMonitors(impl.api);
        const auto thumbButtons = thumbstickButtonMonitors(impl.api);
        const auto buttons = buttonMonitors(impl.api);
        unregisterMonitors(axes, axes.size());
        unregisterMonitors(thumbButtons, thumbButtons.size());
        unregisterMonitors(buttons, buttons.size());
        (void)impl.api.OH_GameDevice_UnregisterDeviceMonitor();
    }
    {
        std::lock_guard<std::mutex> lock(registry.mutex);
        if (registry.active == &impl) {
            registry.active = nullptr;
            registry.activeOwner.reset();
        }
    }
    std::lock_guard<std::mutex> lock(impl.mutex);
    impl.generations.clear();
    impl.sdkIds.clear();
    impl.samples.clear();
    impl.leftTriggerAxisDevices.clear();
    impl.rightTriggerAxisDevices.clear();
    impl.sequences.clear();
    impl.timestamps.clear();
    impl.onlineDevices.clear();
    impl.activeDeviceId = 0U;
    impl.stopDeferred.store(false, std::memory_order_release);
    impl.api.unload();
}

void finishDeferredStop(MoonlightGameControllerListener::Impl& impl) noexcept {
    if (!impl.stopDeferred.load(std::memory_order_acquire)) {
        return;
    }
    std::unique_lock<std::mutex> lifecycleLock(impl.lifecycleMutex,
                                               std::try_to_lock);
    if (!lifecycleLock.owns_lock()) {
        return;
    }
    stopRegisteredListener(impl);
}

} // namespace
#endif // defined(__OHOS__)

MoonlightGameControllerListener::MoonlightGameControllerListener(Sink& sink) noexcept
    : impl_(std::shared_ptr<Impl>(new (std::nothrow) Impl(sink))) {}

MoonlightGameControllerListener::~MoonlightGameControllerListener() {
    stop();
}

bool MoonlightGameControllerListener::start() noexcept {
#if !defined(__OHOS__)
    return false;
#else
    if (impl_ == nullptr) {
        return false;
    }
    if (isCurrentCallback(*impl_)) {
        return impl_->started.load(std::memory_order_acquire);
    }
    if (impl_->started.load(std::memory_order_acquire)) {
        return !impl_->stopDeferred.load(std::memory_order_acquire);
    }
    std::lock_guard<std::mutex> lifecycleLock(impl_->lifecycleMutex);
    if (!impl_->api.load()) {
        return false;
    }
    auto& registry = callbackRegistry();
    {
        std::lock_guard<std::mutex> lock(registry.mutex);
        if (registry.active != nullptr && registry.active != impl_.get()) {
            impl_->api.unload();
            return false;
        }
        if (impl_->started.load(std::memory_order_acquire)) {
            if (!impl_->stopDeferred.load(std::memory_order_acquire)) {
                return true;
            }
            // A callback requested deferred stop while another start raced
            // through the outer fast path. Finish it only outside callbacks.
            return false;
        }
        if (impl_->stopDeferred.load(std::memory_order_acquire)) {
            // The deferred callback lease still owns the process-global table.
            return false;
        }
        if (impl_->registrationActive.load(std::memory_order_acquire)) {
            // stop() has closed admission but has not finished unregistering
            // the process-global monitor table yet.
            return false;
        }
        impl_->registrationActive.store(false, std::memory_order_release);
        registry.active = impl_.get();
        registry.activeOwner = impl_;
    }
    std::size_t registeredButtons = 0U;
    std::size_t registeredThumbButtons = 0U;
    std::size_t registeredAxes = 0U;
    bool deviceRegistered = false;
    const auto buttons = buttonMonitors(impl_->api);
    const auto thumbButtons = thumbstickButtonMonitors(impl_->api);
    const auto axes = axisMonitors(impl_->api);
    if (impl_->api.OH_GameDevice_RegisterDeviceMonitor(deviceCallback) ==
        GAME_CONTROLLER_SUCCESS) {
        deviceRegistered = true;
    }
    const bool ok = deviceRegistered &&
        registerButtonMonitors(buttons, registeredButtons) &&
        registerButtonMonitors(thumbButtons, registeredThumbButtons) &&
        registerAxisMonitors(axes, registeredAxes);
    if (!ok) {
        unregisterMonitors(axes, registeredAxes);
        unregisterMonitors(thumbButtons, registeredThumbButtons);
        unregisterMonitors(buttons, registeredButtons);
        if (deviceRegistered) {
            (void)impl_->api.OH_GameDevice_UnregisterDeviceMonitor();
        }
        impl_->registrationActive.store(false, std::memory_order_release);
        std::unique_lock<std::mutex> lock(registry.mutex);
        impl_->started.store(false, std::memory_order_release);
        // Registration failure can race with a callback already admitted by
        // acquireCallback(). Drain those leases before returning while Impl is
        // still alive; stop() may otherwise observe started=false and skip the
        // teardown fence.
        if (!isCurrentCallback(*impl_)) {
            registry.cv.wait(lock, [&]() { return registry.inFlight == 0U; });
        }
        if (registry.active == impl_.get()) {
            registry.active = nullptr;
            registry.activeOwner.reset();
        }
        impl_->api.unload();
        return false;
    }
    impl_->registrationActive.store(true, std::memory_order_release);
    bool ownsRegistry = false;
    {
        std::lock_guard<std::mutex> lock(registry.mutex);
        ownsRegistry = registry.active == impl_.get() &&
            registry.activeOwner == impl_;
        if (ownsRegistry) {
            // Open callback admission only after every monitor is registered.
            impl_->started.store(true, std::memory_order_release);
        }
    }
    if (!ownsRegistry) {
        stopRegisteredListener(*impl_);
        return false;
    }
    if (impl_->stopDeferred.load(std::memory_order_acquire)) {
        // If this is executing inside the callback that requested stop, the
        // lease will call finishDeferredStop after the callback returns. A
        // different stop() caller will perform the same cleanup after drain.
        if (isCurrentCallback(*impl_)) {
            return false;
        }
        stopRegisteredListener(*impl_);
        return false;
    }
    replayOnlineDevices();
    if (impl_->stopDeferred.load(std::memory_order_acquire)) {
        if (isCurrentCallback(*impl_)) {
            return false;
        }
        stopRegisteredListener(*impl_);
        return false;
    }
    return true;
#endif
}

void MoonlightGameControllerListener::stop() noexcept {
#if defined(__OHOS__)
    if (impl_ == nullptr) {
        return;
    }
    if (isCurrentCallback(*impl_)) {
        requestStopFromCallback(*impl_);
        return;
    }
    std::lock_guard<std::mutex> lifecycleLock(impl_->lifecycleMutex);
    stopRegisteredListener(*impl_);
#else
    (void)impl_;
#endif
}

void MoonlightGameControllerListener::replayOnlineDevices() noexcept {
#if defined(__OHOS__)
    if (impl_ == nullptr || !started()) {
        return;
    }
    std::lock_guard<std::mutex> dispatchLock(impl_->dispatchMutex);
    auto& api = impl_->api;
    GameDevice_AllDeviceInfos* all = nullptr;
    if (api.OH_GameDevice_GetAllDeviceInfos(&all) != GAME_CONTROLLER_SUCCESS || all == nullptr) {
        return;
    }
    int32_t count = 0;
    if (api.OH_GameDevice_AllDeviceInfos_GetCount(all, &count) == GAME_CONTROLLER_SUCCESS) {
        for (int32_t index = 0; index < count; ++index) {
            GameDevice_DeviceInfo* info = nullptr;
            if (api.OH_GameDevice_AllDeviceInfos_GetDeviceInfo(all, index, &info) !=
                    GAME_CONTROLLER_SUCCESS || info == nullptr) {
                continue;
            }
            DeviceInfoCopy copy;
            const bool valid = copyDeviceInfo(api, info, copy);
            (void)api.OH_GameDevice_DestroyDeviceInfo(&info);
            if (valid) {
                const auto id = ensureDevice(*impl_, copy.sdkId.c_str());
                if (id != 0U) {
                    emitConnected(*impl_, id);
                }
            }
        }
    }
    (void)api.OH_GameDevice_DestroyAllDeviceInfos(&all);
#endif
}

bool MoonlightGameControllerListener::started() const noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    return impl_->started.load(std::memory_order_acquire);
}

std::size_t MoonlightGameControllerListener::onlineDeviceCount() const noexcept {
    if (impl_ == nullptr) {
        return 0U;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->onlineDevices.size();
}

std::uint64_t MoonlightGameControllerListener::stableDeviceIdForTesting(
    const char* value) noexcept {
    return stableDeviceId(value);
}

} // namespace remotedesk::moonlight

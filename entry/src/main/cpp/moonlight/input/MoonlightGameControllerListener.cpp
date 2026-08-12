#include "moonlight/input/MoonlightGameControllerListener.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>

#if defined(__OHOS__)
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

std::string lowercase(std::string value) {
    for (char& character : value) {
        character = static_cast<char>(std::tolower(
            static_cast<unsigned char>(character)));
    }
    return value;
}

bool contains(const std::string& value, const char* token) noexcept {
    return value.find(token) != std::string::npos;
}

std::uint32_t buttonBit(const std::string& rawName) noexcept {
    const std::string name = lowercase(rawName);
    if (contains(name, "dpad") || contains(name, "direction")) {
        if (contains(name, "up")) {
            return kMoonlightControllerButtonUp;
        }
        if (contains(name, "down")) {
            return kMoonlightControllerButtonDown;
        }
        if (contains(name, "left")) {
            return kMoonlightControllerButtonLeft;
        }
        if (contains(name, "right")) {
            return kMoonlightControllerButtonRight;
        }
    }
    if (name == "a" || contains(name, "button_a") || contains(name, "buttona")) {
        return kMoonlightControllerButtonA;
    }
    if (name == "b" || contains(name, "button_b") || contains(name, "buttonb")) {
        return kMoonlightControllerButtonB;
    }
    if (name == "x" || contains(name, "button_x") || contains(name, "buttonx")) {
        return kMoonlightControllerButtonX;
    }
    if (name == "y" || contains(name, "button_y") || contains(name, "buttony")) {
        return kMoonlightControllerButtonY;
    }
    if (contains(name, "leftshoulder") || contains(name, "left_shoulder") ||
        contains(name, "leftbumper") || contains(name, "left_bumper") ||
        contains(name, "button_l1") || contains(name, "button_lb")) {
        return kMoonlightControllerButtonLeftShoulder;
    }
    if (contains(name, "rightshoulder") || contains(name, "right_shoulder") ||
        contains(name, "rightbumper") || contains(name, "right_bumper") ||
        contains(name, "button_r1") || contains(name, "button_rb")) {
        return kMoonlightControllerButtonRightShoulder;
    }
    if (contains(name, "leftthumb") || contains(name, "left_thumb") ||
        contains(name, "leftstick") || contains(name, "left_stick")) {
        return kMoonlightControllerButtonLeftStick;
    }
    if (contains(name, "rightthumb") || contains(name, "right_thumb") ||
        contains(name, "rightstick") || contains(name, "right_stick")) {
        return kMoonlightControllerButtonRightStick;
    }
    if (contains(name, "menu") || contains(name, "start")) {
        return kMoonlightControllerButtonPlay;
    }
    return 0U;
}

enum class TriggerButton : std::uint8_t { None, Left, Right };

TriggerButton triggerButton(const std::string& rawName) noexcept {
    const std::string name = lowercase(rawName);
    if ((contains(name, "left") || contains(name, "l2") || contains(name, "lt")) &&
        contains(name, "trigger")) {
        return TriggerButton::Left;
    }
    if ((contains(name, "right") || contains(name, "r2") || contains(name, "rt")) &&
        contains(name, "trigger")) {
        return TriggerButton::Right;
    }
    return TriggerButton::None;
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

void updateHatFromButtons(MoonlightControllerSample& sample) noexcept {
    sample.hasHatAxes = false;
}

struct DeviceInfoCopy final {
    std::uint64_t deviceId = 0U;
    GameDevice_DeviceType type = UNKNOWN;
    std::string sdkId;
};

bool copyDeviceInfo(const GameDevice_DeviceInfo* info,
                    DeviceInfoCopy& output) noexcept {
    if (info == nullptr) {
        return false;
    }
    char* sdkId = nullptr;
    GameDevice_DeviceType type = UNKNOWN;
    if (OH_GameDevice_DeviceInfo_GetDeviceId(info, &sdkId) != GAME_CONTROLLER_SUCCESS ||
        sdkId == nullptr ||
        OH_GameDevice_DeviceInfo_GetDeviceType(info, &type) != GAME_CONTROLLER_SUCCESS) {
        return false;
    }
    output.sdkId = boundedText(sdkId);
    output.deviceId = stableDeviceId(sdkId);
    output.type = type;
    return output.deviceId != 0U && output.type == GAME_PAD;
}

#endif // defined(__OHOS__)

} // namespace

struct MoonlightGameControllerListener::Impl final {
    explicit Impl(Sink& valueSink) noexcept : sink(&valueSink) {}

    Sink* sink = nullptr;
    mutable std::mutex mutex;
    bool started = false;
    std::size_t callbacksInFlight = 0U;
    std::uint64_t nextGeneration = 1U;
    std::unordered_map<std::uint64_t, std::uint64_t> generations;
    std::unordered_map<std::uint64_t, std::string> sdkIds;
    std::unordered_map<std::uint64_t, MoonlightControllerSample> samples;
    std::unordered_map<std::uint64_t, std::uint64_t> sequences;
    std::unordered_map<std::uint64_t, std::uint64_t> timestamps;
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
    std::size_t inFlight = 0U;
};

CallbackRegistry& callbackRegistry() noexcept {
    static CallbackRegistry registry;
    return registry;
}

MoonlightGameControllerListener::Impl* acquireCallback() noexcept {
    auto& registry = callbackRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    if (registry.active == nullptr || !registry.active->started) {
        return nullptr;
    }
    ++registry.inFlight;
    return registry.active;
}

void releaseCallback() noexcept {
    auto& registry = callbackRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    if (registry.inFlight != 0U) {
        --registry.inFlight;
    }
    registry.cv.notify_all();
}

class CallbackLease final {
  public:
    explicit CallbackLease(MoonlightGameControllerListener::Impl* value) noexcept
        : impl(value) {}
    ~CallbackLease() { if (impl != nullptr) { releaseCallback(); } }
    CallbackLease(const CallbackLease&) = delete;
    CallbackLease& operator=(const CallbackLease&) = delete;
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
            const auto generation = impl.nextGeneration == 0U ? 1U : impl.nextGeneration;
            impl.nextGeneration = saturatingIncrement(generation);
            impl.sdkIds.emplace(id, boundedId);
            impl.generations[id] = generation;
            impl.samples[id] = {};
            impl.sequences[id] = 0U;
            impl.timestamps[id] = 0U;
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
    {
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto found = impl.generations.find(id);
        if (found == impl.generations.end()) {
            return;
        }
        generation = found->second;
        if (impl.sequences[id] != 0U) {
            return;
        }
        impl.sequences[id] = 1U;
        impl.timestamps[id] = monotonicNowUs();
    }
    if (impl.sink != nullptr) {
        impl.sink->onPhysicalControllerConnected(id, generation, profile);
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
        impl.sink->onPhysicalControllerSample(id, generation, sequence, timestamp, sample);
    }
}

void emitDisconnected(MoonlightGameControllerListener::Impl& impl,
                      std::uint64_t id) noexcept {
    std::uint64_t generation = 0U;
    std::uint64_t sequence = 0U;
    std::uint64_t timestamp = 0U;
    {
        std::lock_guard<std::mutex> lock(impl.mutex);
        const auto found = impl.generations.find(id);
        if (found == impl.generations.end() || impl.sequences[id] == 0U) {
            return;
        }
        generation = found->second;
        sequence = saturatingIncrement(impl.sequences[id]);
        impl.sequences[id] = sequence;
        timestamp = std::max(saturatingIncrement(impl.timestamps[id]), monotonicNowUs());
        impl.timestamps[id] = timestamp;
        impl.samples[id] = {};
    }
    if (impl.sink != nullptr) {
        impl.sink->onPhysicalControllerDisconnected(id, generation, sequence, timestamp);
    }
    std::lock_guard<std::mutex> lock(impl.mutex);
    impl.sequences[id] = 0U;
    impl.timestamps[id] = 0U;
}

void buttonCallback(const GamePad_ButtonEvent* event) {
    CallbackLease lease(acquireCallback());
    if (lease.impl == nullptr || event == nullptr) {
        return;
    }
    char* sdkId = nullptr;
    char* codeName = nullptr;
    GamePad_Button_ActionType action = UP;
    if (OH_GamePad_ButtonEvent_GetDeviceId(event, &sdkId) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_ButtonEvent_GetButtonAction(event, &action) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_ButtonEvent_GetButtonCodeName(event, &codeName) != GAME_CONTROLLER_SUCCESS) {
        return;
    }
    const auto id = ensureDevice(*lease.impl, sdkId);
    if (id == 0U) {
        return;
    }
    emitConnected(*lease.impl, id);
    MoonlightControllerSample copy;
    {
        std::lock_guard<std::mutex> lock(lease.impl->mutex);
        auto& sample = lease.impl->samples[id];
        const std::string name = boundedText(codeName);
        const auto bit = buttonBit(name);
        if (bit != 0U) {
            if (action == DOWN) {
                sample.buttonFlags |= bit;
            } else {
                sample.buttonFlags &= ~bit;
            }
            updateHatFromButtons(sample);
        } else {
            const auto trigger = triggerButton(name);
            if (trigger == TriggerButton::Left) {
                sample.leftTrigger = action == DOWN ? 1.0 : 0.0;
            } else if (trigger == TriggerButton::Right) {
                sample.rightTrigger = action == DOWN ? 1.0 : 0.0;
            } else {
                return;
            }
        }
        copy = sample;
    }
    emitSample(*lease.impl, id, copy);
}

void axisCallback(const GamePad_AxisEvent* event) {
    CallbackLease lease(acquireCallback());
    if (lease.impl == nullptr || event == nullptr) {
        return;
    }
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
    if (OH_GamePad_AxisEvent_GetDeviceId(event, &sdkId) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetAxisSourceType(event, &source) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetXAxisValue(event, &x) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetYAxisValue(event, &y) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetZAxisValue(event, &z) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetRZAxisValue(event, &rz) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetHatXAxisValue(event, &hatX) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetHatYAxisValue(event, &hatY) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetBrakeAxisValue(event, &brake) != GAME_CONTROLLER_SUCCESS ||
        OH_GamePad_AxisEvent_GetGasAxisValue(event, &gas) != GAME_CONTROLLER_SUCCESS) {
        return;
    }
    const auto id = ensureDevice(*lease.impl, sdkId);
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
                sample.leftTrigger = clampTrigger(std::max(z, brake));
                break;
            case RIGHT_TRIGGER:
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
    GameDevice_StatusChangedType status = OFFLINE;
    GameDevice_DeviceInfo* info = nullptr;
    if (OH_GameDevice_DeviceEvent_GetChangedType(event, &status) != GAME_CONTROLLER_SUCCESS ||
        OH_GameDevice_DeviceEvent_GetDeviceInfo(event, &info) != GAME_CONTROLLER_SUCCESS ||
        info == nullptr) {
        return;
    }
    DeviceInfoCopy copy;
    const bool valid = copyDeviceInfo(info, copy);
    (void)OH_GameDevice_DestroyDeviceInfo(&info);
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
};

struct AxisMonitorRegistration final {
    GameController_ErrorCode (*registerMonitor)(GamePad_AxisInputMonitorCallback);
    GameController_ErrorCode (*unregisterMonitor)();
};

const std::array<ButtonMonitorRegistration, 15U>& buttonMonitors() {
    static const std::array<ButtonMonitorRegistration, 15U> value = {{
        {OH_GamePad_LeftShoulder_RegisterButtonInputMonitor,
         OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor},
        {OH_GamePad_RightShoulder_RegisterButtonInputMonitor,
         OH_GamePad_RightShoulder_UnregisterButtonInputMonitor},
        {OH_GamePad_LeftTrigger_RegisterButtonInputMonitor,
         OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor},
        {OH_GamePad_RightTrigger_RegisterButtonInputMonitor,
         OH_GamePad_RightTrigger_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonMenu_RegisterButtonInputMonitor,
         OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonHome_RegisterButtonInputMonitor,
         OH_GamePad_ButtonHome_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonA_RegisterButtonInputMonitor,
         OH_GamePad_ButtonA_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonB_RegisterButtonInputMonitor,
         OH_GamePad_ButtonB_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonX_RegisterButtonInputMonitor,
         OH_GamePad_ButtonX_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonY_RegisterButtonInputMonitor,
         OH_GamePad_ButtonY_UnregisterButtonInputMonitor},
        {OH_GamePad_ButtonC_RegisterButtonInputMonitor,
         OH_GamePad_ButtonC_UnregisterButtonInputMonitor},
        {OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor,
         OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor},
        {OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor,
         OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor},
        {OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor,
         OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor},
        {OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor,
         OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor},
    }};
    return value;
}

const std::array<ButtonMonitorRegistration, 2U>& thumbstickButtonMonitors() {
    static const std::array<ButtonMonitorRegistration, 2U> value = {{
        {OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor,
         OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor},
        {OH_GamePad_RightThumbstick_RegisterButtonInputMonitor,
         OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor},
    }};
    return value;
}

const std::array<AxisMonitorRegistration, 5U>& axisMonitors() {
    static const std::array<AxisMonitorRegistration, 5U> value = {{
        {OH_GamePad_LeftTrigger_RegisterAxisInputMonitor,
         OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor},
        {OH_GamePad_RightTrigger_RegisterAxisInputMonitor,
         OH_GamePad_RightTrigger_UnregisterAxisInputMonitor},
        {OH_GamePad_Dpad_RegisterAxisInputMonitor,
         OH_GamePad_Dpad_UnregisterAxisInputMonitor},
        {OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor,
         OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor},
        {OH_GamePad_RightThumbstick_RegisterAxisInputMonitor,
         OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor},
    }};
    return value;
}

template <typename Registration, typename Callback, std::size_t N>
bool registerMonitors(const std::array<Registration, N>& monitors, Callback callback,
                      std::size_t& registered) noexcept {
    for (const auto& monitor : monitors) {
        if (monitor.registerMonitor(callback) != GAME_CONTROLLER_SUCCESS) {
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

} // namespace
#endif // defined(__OHOS__)

MoonlightGameControllerListener::MoonlightGameControllerListener(Sink& sink) noexcept
    : impl_(std::unique_ptr<Impl>(new (std::nothrow) Impl(sink))) {}

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
    auto& registry = callbackRegistry();
    {
        std::lock_guard<std::mutex> lock(registry.mutex);
        if (registry.active != nullptr && registry.active != impl_.get()) {
            return false;
        }
        if (impl_->started) {
            return true;
        }
        registry.active = impl_.get();
        impl_->started = true;
    }
    std::size_t registeredButtons = 0U;
    std::size_t registeredThumbButtons = 0U;
    std::size_t registeredAxes = 0U;
    bool deviceRegistered = false;
    if (OH_GameDevice_RegisterDeviceMonitor(deviceCallback) == GAME_CONTROLLER_SUCCESS) {
        deviceRegistered = true;
    }
    const bool ok = deviceRegistered &&
        registerMonitors(buttonMonitors(), buttonCallback, registeredButtons) &&
        registerMonitors(thumbstickButtonMonitors(), buttonCallback, registeredThumbButtons) &&
        registerMonitors(axisMonitors(), axisCallback, registeredAxes);
    if (!ok) {
        unregisterMonitors(axisMonitors(), registeredAxes);
        unregisterMonitors(thumbstickButtonMonitors(), registeredThumbButtons);
        unregisterMonitors(buttonMonitors(), registeredButtons);
        if (deviceRegistered) {
            (void)OH_GameDevice_UnregisterDeviceMonitor();
        }
        std::lock_guard<std::mutex> lock(registry.mutex);
        impl_->started = false;
        if (registry.active == impl_.get()) {
            registry.active = nullptr;
        }
        return false;
    }
    replayOnlineDevices();
    return true;
#endif
}

void MoonlightGameControllerListener::stop() noexcept {
#if defined(__OHOS__)
    if (impl_ == nullptr) {
        return;
    }
    auto& registry = callbackRegistry();
    {
        std::unique_lock<std::mutex> lock(registry.mutex);
        if (!impl_->started) {
            if (registry.active == impl_.get()) {
                registry.active = nullptr;
            }
            return;
        }
        impl_->started = false;
        if (registry.active == impl_.get()) {
            registry.active = nullptr;
        }
        registry.cv.wait(lock, [&]() { return registry.inFlight == 0U; });
    }
    unregisterMonitors(axisMonitors(), axisMonitors().size());
    unregisterMonitors(thumbstickButtonMonitors(), thumbstickButtonMonitors().size());
    unregisterMonitors(buttonMonitors(), buttonMonitors().size());
    (void)OH_GameDevice_UnregisterDeviceMonitor();
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->generations.clear();
    impl_->sdkIds.clear();
    impl_->samples.clear();
    impl_->sequences.clear();
    impl_->timestamps.clear();
#else
    (void)impl_;
#endif
}

void MoonlightGameControllerListener::replayOnlineDevices() noexcept {
#if defined(__OHOS__)
    if (impl_ == nullptr || !started()) {
        return;
    }
    GameDevice_AllDeviceInfos* all = nullptr;
    if (OH_GameDevice_GetAllDeviceInfos(&all) != GAME_CONTROLLER_SUCCESS || all == nullptr) {
        return;
    }
    int32_t count = 0;
    if (OH_GameDevice_AllDeviceInfos_GetCount(all, &count) == GAME_CONTROLLER_SUCCESS) {
        for (int32_t index = 0; index < count; ++index) {
            GameDevice_DeviceInfo* info = nullptr;
            if (OH_GameDevice_AllDeviceInfos_GetDeviceInfo(all, index, &info) !=
                    GAME_CONTROLLER_SUCCESS || info == nullptr) {
                continue;
            }
            DeviceInfoCopy copy;
            if (copyDeviceInfo(info, copy)) {
                const auto id = ensureDevice(*impl_, copy.sdkId.c_str());
                if (id != 0U) {
                    emitConnected(*impl_, id);
                }
            }
        }
    }
    (void)OH_GameDevice_DestroyAllDeviceInfos(&all);
#endif
}

bool MoonlightGameControllerListener::started() const noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->started;
}

std::size_t MoonlightGameControllerListener::onlineDeviceCount() const noexcept {
    if (impl_ == nullptr) {
        return 0U;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    std::size_t count = 0U;
    for (const auto& item : impl_->sequences) {
        count += item.second != 0U ? 1U : 0U;
    }
    return count;
}

std::uint64_t MoonlightGameControllerListener::stableDeviceIdForTesting(
    const char* value) noexcept {
    return stableDeviceId(value);
}

} // namespace remotedesk::moonlight

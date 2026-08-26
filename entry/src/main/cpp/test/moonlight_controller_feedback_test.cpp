#include "moonlight/input/MoonlightControllerFeedback.h"
#include "test/test_runner.h"

#include <array>
#include <limits>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightInputIdentity feedbackIdentity(std::uint64_t owner = 9301U) {
    return {{7301U, 11U, owner}, 19U};
}

MoonlightControllerFeedbackContext feedbackContext(
    const MoonlightInputIdentity& identity, std::uint64_t operation,
    std::uint64_t timestamp = 0U, std::uint64_t deviceId = 71U,
    std::uint64_t deviceGeneration = 5U) {
    return {identity, 0U, deviceId, deviceGeneration, operation,
            timestamp == 0U ? 1000000U + operation * 10000U : timestamp};
}

MoonlightControllerFeedbackEvidence fullFeedbackEvidence() {
    MoonlightControllerFeedbackEvidence evidence;
    evidence.officialApiMask = kMoonlightControllerFeedbackCapabilityMask;
    evidence.physicalDeviceMask = kMoonlightControllerFeedbackCapabilityMask;
    evidence.adaptiveTriggersOfficialApi = true;
    evidence.adaptiveTriggersPhysicalDevice = true;
    evidence.platformGeneration = 7U;
    evidence.deviceGeneration = 5U;
    return evidence;
}

class FeedbackOwnerGate final : public MoonlightInputOwnerGate {
  public:
    bool withOwner(const MoonlightInputIdentity& identity,
                   MoonlightInputOwnedOperation& operation) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++calls_;
        if (!available_ || identity != accepted_) {
            return false;
        }
        operation.execute();
        return true;
    }

    void accept(const MoonlightInputIdentity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        accepted_ = identity;
    }

    void setAvailable(bool available) {
        std::lock_guard<std::mutex> lock(mutex_);
        available_ = available;
    }

    std::size_t calls() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return calls_;
    }

  private:
    mutable std::mutex mutex_;
    MoonlightInputIdentity accepted_{};
    bool available_ = true;
    std::size_t calls_ = 0U;
};

struct FeedbackPortEvent final {
    MoonlightControllerFeedbackContext context{};
    MoonlightControllerFeedbackCommand command{};
};

class FeedbackPort final : public MoonlightControllerFeedbackPort {
  public:
    MoonlightControllerFeedbackPortStatus submit(
        const MoonlightControllerFeedbackContext& context,
        const MoonlightControllerFeedbackCommand& command) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        events_.push_back({context, command});
        if (submitIndex_ < submitScript_.size()) {
            return submitScript_[submitIndex_++];
        }
        return submitStatus;
    }

    MoonlightControllerFeedbackPortStatus releaseDevice(
        const MoonlightControllerFeedbackContext& context) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        releases_.push_back(context);
        if (releaseIndex_ < releaseScript_.size()) {
            return releaseScript_[releaseIndex_++];
        }
        return releaseStatus;
    }

    void setSubmitScript(std::vector<MoonlightControllerFeedbackPortStatus> script) {
        std::lock_guard<std::mutex> lock(mutex_);
        submitScript_ = std::move(script);
        submitIndex_ = 0U;
    }

    void setReleaseScript(std::vector<MoonlightControllerFeedbackPortStatus> script) {
        std::lock_guard<std::mutex> lock(mutex_);
        releaseScript_ = std::move(script);
        releaseIndex_ = 0U;
    }

    FeedbackPortEvent eventAt(std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        RDP_ASSERT(index < events_.size());
        return events_[index];
    }

    std::size_t eventCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_.size();
    }

    std::size_t releaseCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return releases_.size();
    }

    MoonlightControllerFeedbackPortStatus submitStatus =
        MoonlightControllerFeedbackPortStatus::Accepted;
    MoonlightControllerFeedbackPortStatus releaseStatus =
        MoonlightControllerFeedbackPortStatus::Accepted;

  private:
    mutable std::mutex mutex_;
    std::vector<MoonlightControllerFeedbackPortStatus> submitScript_;
    std::vector<MoonlightControllerFeedbackPortStatus> releaseScript_;
    std::size_t submitIndex_ = 0U;
    std::size_t releaseIndex_ = 0U;
    std::vector<FeedbackPortEvent> events_;
    std::vector<MoonlightControllerFeedbackContext> releases_;
};

struct FeedbackFixture final {
    explicit FeedbackFixture(MoonlightControllerFeedbackLimits limits = {}) {
        gate->accept(identity);
        feedback = MoonlightControllerFeedback::create(gate, port, limits);
        RDP_ASSERT(feedback != nullptr);
    }

    void bind(const MoonlightControllerFeedbackEvidence& evidence =
                  fullFeedbackEvidence()) {
        RDP_ASSERT_EQ(feedback->bind(feedbackContext(identity, 1U), evidence).status,
                      MoonlightControllerFeedbackStatus::Applied);
    }

    MoonlightInputIdentity identity = feedbackIdentity();
    std::shared_ptr<FeedbackOwnerGate> gate =
        std::make_shared<FeedbackOwnerGate>();
    std::shared_ptr<FeedbackPort> port = std::make_shared<FeedbackPort>();
    std::shared_ptr<MoonlightControllerFeedback> feedback;
};

RDP_TEST_CASE(moonlight_controller_feedback_api23_product_evidence_is_all_false) {
    const auto evidence = moonlightApi23ControllerFeedbackEvidence();
    RDP_ASSERT_EQ(evidence.officialApiMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(evidence.physicalDeviceMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT(!evidence.adaptiveTriggersOfficialApi);
    RDP_ASSERT(!evidence.adaptiveTriggersPhysicalDevice);
    RDP_ASSERT_EQ(evidence.enabledMask(), static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(kMoonlightControllerCapabilityRumble,
                  static_cast<std::uint16_t>(0x02));
    RDP_ASSERT_EQ(kMoonlightControllerCapabilityRgbLed,
                  static_cast<std::uint16_t>(0x80));
}

RDP_TEST_CASE(moonlight_controller_feedback_creation_and_evidence_are_strict) {
    auto gate = std::make_shared<FeedbackOwnerGate>();
    auto port = std::make_shared<FeedbackPort>();
    MoonlightControllerFeedbackLimits limits;
    limits.maximumMotionReportRateHz = 0U;
    RDP_ASSERT(MoonlightControllerFeedback::create(gate, port, limits) == nullptr);
    limits = {};
    limits.maximumGyroscopeMagnitude =
        std::numeric_limits<float>::infinity();
    RDP_ASSERT(MoonlightControllerFeedback::create(gate, port, limits) == nullptr);
    RDP_ASSERT(MoonlightControllerFeedback::create(nullptr, port) == nullptr);
    RDP_ASSERT(MoonlightControllerFeedback::create(gate, nullptr) == nullptr);

    FeedbackFixture fixture;
    MoonlightControllerFeedbackEvidence evidence;
    evidence.physicalDeviceMask = kMoonlightControllerCapabilityRumble;
    evidence.deviceGeneration = 5U;
    RDP_ASSERT_EQ(fixture.feedback->bind(
        feedbackContext(fixture.identity, 1U), evidence).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
    evidence = fullFeedbackEvidence();
    evidence.platformGeneration = 0U;
    RDP_ASSERT_EQ(fixture.feedback->bind(
        feedbackContext(fixture.identity, 1U), evidence).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
    evidence = fullFeedbackEvidence();
    evidence.deviceGeneration = 6U;
    RDP_ASSERT_EQ(fixture.feedback->bind(
        feedbackContext(fixture.identity, 1U), evidence).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_controller_feedback_unsupported_capabilities_make_zero_port_calls) {
    FeedbackFixture fixture;
    fixture.bind(moonlightApi23ControllerFeedbackEvidence());
    const std::array<MoonlightControllerFeedbackCommand, 7U> commands{
        makeMoonlightRumbleCommand(1U, 2U),
        makeMoonlightTriggerRumbleCommand(3U, 4U),
        makeMoonlightRgbLedCommand(5U, 6U, 7U),
        makeMoonlightAdaptiveTriggerCommand(0U, 0U, 0U, {}, {}),
        makeMoonlightMotionReportCommand(
            MoonlightControllerMotionType::Accelerometer, 100U),
        makeMoonlightMotionSampleCommand(
            MoonlightControllerMotionType::Gyroscope, 1.0F, 2.0F, 3.0F),
        makeMoonlightBatteryCommand(
            MoonlightControllerBatteryState::Charging, 50U),
    };
    std::uint64_t operation = 2U;
    for (const auto& command : commands) {
        RDP_ASSERT_EQ(fixture.feedback->dispatch(
            feedbackContext(fixture.identity, operation++), command).status,
            MoonlightControllerFeedbackStatus::Unsupported);
    }
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.port->releaseCount(), static_cast<std::size_t>(0));
    const auto snapshot = fixture.feedback->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.unsupportedOperations, static_cast<std::uint64_t>(7));
    RDP_ASSERT_EQ(snapshot.advertisedCapabilityMask,
                  static_cast<std::uint16_t>(0));
}

RDP_TEST_CASE(moonlight_controller_feedback_advertises_only_api_device_intersection) {
    FeedbackFixture fixture;
    auto evidence = fullFeedbackEvidence();
    evidence.officialApiMask = kMoonlightControllerCapabilityRumble |
        kMoonlightControllerCapabilityBattery |
        kMoonlightControllerCapabilityRgbLed;
    evidence.physicalDeviceMask = kMoonlightControllerCapabilityRumble |
        kMoonlightControllerCapabilityBattery;
    evidence.adaptiveTriggersOfficialApi = false;
    evidence.adaptiveTriggersPhysicalDevice = false;
    fixture.bind(evidence);
    const auto snapshot = fixture.feedback->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.advertisedCapabilityMask,
                  kMoonlightControllerCapabilityRumble |
                      kMoonlightControllerCapabilityBattery);
    RDP_ASSERT(!snapshot.adaptiveTriggersEnabled);
}

RDP_TEST_CASE(moonlight_controller_feedback_projects_output_commands_exactly) {
    FeedbackFixture fixture;
    fixture.bind();
    std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes> left{};
    std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes> right{};
    left[0] = 0x11U;
    right[9] = 0x22U;
    const std::array<MoonlightControllerFeedbackCommand, 4U> commands{
        makeMoonlightRumbleCommand(0x1234U, 0x5678U),
        makeMoonlightTriggerRumbleCommand(0x9ABCU, 0xDEF0U),
        makeMoonlightRgbLedCommand(1U, 2U, 3U),
        makeMoonlightAdaptiveTriggerCommand(
            kMoonlightAdaptiveTriggerLeft | kMoonlightAdaptiveTriggerRight,
            4U, 5U, left, right),
    };
    for (std::size_t index = 0U; index < commands.size(); ++index) {
        RDP_ASSERT_EQ(fixture.feedback->dispatch(
            feedbackContext(fixture.identity, index + 2U), commands[index]).status,
            MoonlightControllerFeedbackStatus::Applied);
        const auto event = fixture.port->eventAt(index);
        RDP_ASSERT_EQ(event.command.kind, commands[index].kind);
        RDP_ASSERT_EQ(event.command.firstMotor, commands[index].firstMotor);
        RDP_ASSERT_EQ(event.command.secondMotor, commands[index].secondMotor);
        RDP_ASSERT(event.command.adaptiveLeft == commands[index].adaptiveLeft);
        RDP_ASSERT(event.command.adaptiveRight == commands[index].adaptiveRight);
    }
    RDP_ASSERT(fixture.feedback->snapshot(fixture.identity).releaseRequired);
}

RDP_TEST_CASE(moonlight_controller_feedback_motion_rate_is_capped_and_samples_are_bounded) {
    FeedbackFixture fixture;
    fixture.bind();
    const auto report = fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightMotionReportCommand(
            MoonlightControllerMotionType::Accelerometer, 500U));
    RDP_ASSERT_EQ(report.status, MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT(report.adjusted);
    RDP_ASSERT_EQ(fixture.port->eventAt(0U).command.motionReportRateHz,
                  static_cast<std::uint16_t>(200));

    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 3U, 1030000U),
        makeMoonlightMotionSampleCommand(
            MoonlightControllerMotionType::Accelerometer,
            1.0F, 2.0F, 3.0F)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 4U, 1036000U),
        makeMoonlightMotionSampleCommand(
            MoonlightControllerMotionType::Accelerometer,
            1.0F, 2.0F, 3.0F)).status,
        MoonlightControllerFeedbackStatus::RateLimited);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 5U, 1037000U),
        makeMoonlightMotionSampleCommand(
            MoonlightControllerMotionType::Accelerometer,
            4.0F, 5.0F, 6.0F)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(3));

    const auto bad = makeMoonlightMotionSampleCommand(
        MoonlightControllerMotionType::Gyroscope,
        5000.0F, 0.0F, 0.0F);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 6U), bad).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_controller_feedback_motion_requires_exact_requested_sensor) {
    FeedbackFixture fixture;
    fixture.bind();
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightMotionSampleCommand(
            MoonlightControllerMotionType::Gyroscope,
            1.0F, 2.0F, 3.0F)).status,
        MoonlightControllerFeedbackStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightMotionReportCommand(
            MoonlightControllerMotionType::Gyroscope, 100U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 3U),
        makeMoonlightMotionSampleCommand(
            MoonlightControllerMotionType::Accelerometer,
            1.0F, 2.0F, 3.0F)).status,
        MoonlightControllerFeedbackStatus::InvalidState);
}

RDP_TEST_CASE(moonlight_controller_feedback_battery_is_change_driven_and_120s_bounded) {
    FeedbackFixture fixture;
    fixture.bind();
    const auto battery = makeMoonlightBatteryCommand(
        MoonlightControllerBatteryState::Discharging, 80U);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U, 2000000U), battery).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 3U, 3000000U), battery).status,
        MoonlightControllerFeedbackStatus::RateLimited);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 4U, 4000000U),
        makeMoonlightBatteryCommand(
            MoonlightControllerBatteryState::Charging, 81U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 5U, 124000000U),
        makeMoonlightBatteryCommand(
            MoonlightControllerBatteryState::Charging, 81U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(3));
}

RDP_TEST_CASE(moonlight_controller_feedback_backpressure_retries_only_exact_command) {
    FeedbackFixture fixture;
    fixture.bind();
    fixture.port->setSubmitScript({
        MoonlightControllerFeedbackPortStatus::Backpressure,
        MoonlightControllerFeedbackPortStatus::Accepted});
    const auto context = feedbackContext(fixture.identity, 2U);
    const auto command = makeMoonlightRumbleCommand(100U, 200U);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(context, command).status,
                  MoonlightControllerFeedbackStatus::Backpressure);
    RDP_ASSERT(fixture.feedback->snapshot(fixture.identity).commandPending);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 3U),
        makeMoonlightRgbLedCommand(1U, 2U, 3U)).status,
        MoonlightControllerFeedbackStatus::Backpressure);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(context, command).status,
                  MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT(!fixture.feedback->snapshot(fixture.identity).commandPending);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_controller_feedback_port_unsupported_demotes_exact_capability) {
    FeedbackFixture fixture;
    fixture.bind();
    fixture.port->submitStatus =
        MoonlightControllerFeedbackPortStatus::Unsupported;
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightRgbLedCommand(1U, 2U, 3U)).status,
        MoonlightControllerFeedbackStatus::Unsupported);
    RDP_ASSERT_EQ(fixture.feedback->snapshot(fixture.identity).
                      advertisedCapabilityMask &
                      kMoonlightControllerCapabilityRgbLed,
                  static_cast<std::uint16_t>(0));
    fixture.port->submitStatus = MoonlightControllerFeedbackPortStatus::Accepted;
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 3U),
        makeMoonlightRgbLedCommand(3U, 2U, 1U)).status,
        MoonlightControllerFeedbackStatus::Unsupported);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_controller_feedback_owner_device_and_generation_are_exact) {
    FeedbackFixture fixture;
    fixture.bind();
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(feedbackIdentity(9999U), 2U),
        makeMoonlightRumbleCommand(1U, 2U)).status,
        MoonlightControllerFeedbackStatus::StaleOwner);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U, 0U, 72U),
        makeMoonlightRumbleCommand(1U, 2U)).status,
        MoonlightControllerFeedbackStatus::StaleDevice);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U, 0U, 71U, 6U),
        makeMoonlightRumbleCommand(1U, 2U)).status,
        MoonlightControllerFeedbackStatus::StaleDevice);
    fixture.gate->setAvailable(false);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightRumbleCommand(1U, 2U)).status,
        MoonlightControllerFeedbackStatus::StaleOwner);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_controller_feedback_stale_and_duplicate_operations_are_stable) {
    FeedbackFixture fixture;
    fixture.bind();
    const auto command = makeMoonlightRumbleCommand(1U, 2U);
    const auto context = feedbackContext(fixture.identity, 2U);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(context, command).status,
                  MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(context, command).status,
                  MoonlightControllerFeedbackStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 1U), command).status,
        MoonlightControllerFeedbackStatus::StaleOperation);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightRumbleCommand(3U, 4U)).status,
        MoonlightControllerFeedbackStatus::StaleOperation);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_controller_feedback_suspend_releases_and_resume_never_replays) {
    FeedbackFixture fixture;
    fixture.bind();
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightRumbleCommand(1U, 2U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->suspend(
        feedbackContext(fixture.identity, 3U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->releaseCount(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 4U),
        makeMoonlightRumbleCommand(3U, 4U)).status,
        MoonlightControllerFeedbackStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.feedback->resume(
        feedbackContext(fixture.identity, 4U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(1));
    const auto snapshot = fixture.feedback->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.state, MoonlightControllerFeedbackState::Active);
    RDP_ASSERT(!snapshot.releaseRequired);
}

RDP_TEST_CASE(moonlight_controller_feedback_release_backpressure_blocks_until_exact_retry) {
    FeedbackFixture fixture;
    fixture.bind();
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightTriggerRumbleCommand(1U, 2U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    fixture.port->setReleaseScript({
        MoonlightControllerFeedbackPortStatus::Backpressure,
        MoonlightControllerFeedbackPortStatus::Accepted});
    const auto context = feedbackContext(fixture.identity, 3U);
    RDP_ASSERT_EQ(fixture.feedback->unbind(context).status,
                  MoonlightControllerFeedbackStatus::Backpressure);
    RDP_ASSERT_EQ(fixture.feedback->unbind(
        feedbackContext(fixture.identity, 4U)).status,
        MoonlightControllerFeedbackStatus::Backpressure);
    RDP_ASSERT_EQ(fixture.feedback->unbind(context).status,
                  MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->releaseCount(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(fixture.feedback->snapshot(fixture.identity).state,
                  MoonlightControllerFeedbackState::Idle);

    auto newEvidence = fullFeedbackEvidence();
    newEvidence.deviceGeneration = 6U;
    RDP_ASSERT_EQ(fixture.feedback->bind(
        feedbackContext(fixture.identity, 4U, 0U, 72U, 6U),
        newEvidence).status,
        MoonlightControllerFeedbackStatus::Applied);
}

RDP_TEST_CASE(moonlight_controller_feedback_cleanup_and_destructor_release_are_bounded) {
    FeedbackFixture fixture;
    fixture.bind();
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightMotionReportCommand(
            MoonlightControllerMotionType::Gyroscope, 100U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->cleanup(
        feedbackContext(fixture.identity, 3U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    RDP_ASSERT_EQ(fixture.feedback->cleanup(
        feedbackContext(fixture.identity, 3U)).status,
        MoonlightControllerFeedbackStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.port->releaseCount(), static_cast<std::size_t>(1));
    fixture.feedback.reset();
    RDP_ASSERT_EQ(fixture.port->releaseCount(), static_cast<std::size_t>(1));

    FeedbackFixture destructorFixture;
    destructorFixture.bind();
    RDP_ASSERT_EQ(destructorFixture.feedback->dispatch(
        feedbackContext(destructorFixture.identity, 2U),
        makeMoonlightRgbLedCommand(1U, 2U, 3U)).status,
        MoonlightControllerFeedbackStatus::Applied);
    destructorFixture.feedback.reset();
    RDP_ASSERT_EQ(destructorFixture.port->releaseCount(),
                  static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_controller_feedback_malformed_payloads_fail_before_port) {
    FeedbackFixture fixture;
    fixture.bind();
    std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes> left{};
    left[0] = 1U;
    auto adaptive = makeMoonlightAdaptiveTriggerCommand(0U, 1U, 0U, left, {});
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U), adaptive).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U),
        makeMoonlightBatteryCommand(
            MoonlightControllerBatteryState::Charging, 101U)).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
    auto motion = makeMoonlightMotionSampleCommand(
        MoonlightControllerMotionType::Accelerometer,
        std::numeric_limits<float>::quiet_NaN(), 0.0F, 0.0F);
    RDP_ASSERT_EQ(fixture.feedback->dispatch(
        feedbackContext(fixture.identity, 2U), motion).status,
        MoonlightControllerFeedbackStatus::InvalidRequest);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
}

} // namespace

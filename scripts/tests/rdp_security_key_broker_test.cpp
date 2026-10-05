// Host test for the RDP security-key broker (entry/src/main/cpp/rdp/rdp_security_key_broker.cpp).
// Built and run by scripts/tests/test_rdp_security_key_broker.py with ASan/UBSan.
#include "rdp_security_key_broker.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <thread>

using namespace RdpSecurityKey;
using namespace std::chrono_literals;

namespace {
int failures = 0;
#define CHECK(condition)                                                                 \
    do {                                                                                 \
        if (!(condition)) {                                                              \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);   \
            ++failures;                                                                  \
        }                                                                                \
    } while (0)

// Polls until a request of the given kind arrives (or 2 s pass).
bool Next(Broker& broker, Request& request, Kind kind) {
    for (int i = 0; i < 400; ++i) {
        if (broker.Poll(request)) {
            if (request.kind == kind) return true;
            continue;
        }
        std::this_thread::sleep_for(5ms);
    }
    return false;
}

Reply Ok(const std::string& text = "") {
    Reply reply;
    reply.ok = true;
    reply.text = text;
    return reply;
}

void ConfirmRoundTrip() {
    Broker broker(7);
    CHECK(broker.Begin());
    auto accepted = std::async(std::launch::async, [&] { return broker.Confirm("webauthn.io", 1); });
    Request request;
    CHECK(Next(broker, request, Kind::Confirm));
    CHECK(request.text == "webauthn.io");
    CHECK(request.operation == 1);
    CHECK(!broker.Respond(request.id + 1, Ok()));
    CHECK(broker.Respond(request.id, Ok()));
    CHECK(!broker.Respond(request.id, Ok()));
    CHECK(accepted.get());

    auto rejected = std::async(std::launch::async, [&] { return broker.Confirm("github.com", 2); });
    CHECK(Next(broker, request, Kind::Confirm));
    Reply no;
    CHECK(broker.Respond(request.id, no));
    CHECK(!rejected.get());

    CHECK(!broker.Confirm("", 1));
    CHECK(!broker.Confirm("example.com", 3));
    CHECK(SanitizeRpId(std::string("bad\x01host\xe4 x", 10)) == "bad?host??");
    CHECK(SanitizeRpId(std::string(400, 'a')).size() == kMaxRpIdLength);
}

void CancelEndsUserPromptsButNotIo() {
    // Declared before the broker: its destructor closes it, which reports the cancellation.
    std::atomic<bool> eventCancelled{false};
    Broker broker(8);
    broker.OnCancelChanged([&](bool cancelled) { eventCancelled = cancelled; });
    CHECK(broker.Begin());
    auto confirm = std::async(std::launch::async, [&] { return broker.Confirm("webauthn.io", 1); });
    Request request;
    CHECK(Next(broker, request, Kind::Confirm));
    broker.Cancel();
    CHECK(eventCancelled.load());
    CHECK(confirm.wait_for(1s) == std::future_status::ready);
    CHECK(!confirm.get());
    CHECK(!broker.Respond(request.id, Ok()));
    // While cancelled, prompts fail immediately but device I/O (the CTAPHID_CANCEL write) still goes through.
    CHECK(!broker.Pin(3).has_value());
    auto write = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        report[4] = 0x91;
        return broker.WriteReport(report);
    });
    CHECK(Next(broker, request, Kind::Write));
    CHECK(request.report[4] == 0x91);
    CHECK(broker.Respond(request.id, Ok()));
    CHECK(write.get());
    CHECK(broker.Begin());
    CHECK(!eventCancelled.load());
}

void SelectPinAndReports() {
    Broker broker(9);
    std::string product;
    CHECK(!broker.Authorized(product));
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker.Select(name) ? name : std::string("<none>");
    });
    Request request;
    CHECK(Next(broker, request, Kind::Select));
    CHECK(broker.Respond(request.id, Ok("Key\x07 \x1b[31m5C")));
    CHECK(select.get() == "Key [31m5C");
    CHECK(broker.Authorized(product) && product == "Key [31m5C");

    auto pin = std::async(std::launch::async, [&] { return broker.Pin(5); });
    CHECK(Next(broker, request, Kind::Pin));
    CHECK(request.retries == 5);
    CHECK(broker.Respond(request.id, Ok("123456")));
    const auto entered = pin.get();
    CHECK(entered.has_value() && *entered == "123456");

    auto nulPin = std::async(std::launch::async, [&] { return broker.Pin(-1); });
    CHECK(Next(broker, request, Kind::Pin));
    CHECK(broker.Respond(request.id, Ok(std::string("12\0" "34", 5))));
    CHECK(!nulPin.get().has_value());

    auto longPin = std::async(std::launch::async, [&] { return broker.Pin(-1); });
    CHECK(Next(broker, request, Kind::Pin));
    CHECK(broker.Respond(request.id, Ok(std::string(kMaxPinBytes + 1, '1'))));
    CHECK(!longPin.get().has_value());

    auto read = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return broker.ReadReport(report, 100000) ? report[7] : 0;
    });
    CHECK(Next(broker, request, Kind::Read));
    CHECK(request.timeoutMs == kMaxReadMs);
    Reply data = Ok();
    data.report[4] = 0x90;
    data.report[5] = 0x00;
    data.report[6] = 0x10;
    data.report[7] = 0x42;
    CHECK(broker.Respond(request.id, data));
    CHECK(read.get() == 0x42);

    auto oversized = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return broker.ReadReport(report, 50);
    });
    CHECK(Next(broker, request, Kind::Read));
    CHECK(request.timeoutMs == 50);
    data.report[5] = 0x1d;  // 7614 > 7609
    data.report[6] = 0xbe;
    CHECK(broker.Respond(request.id, data));
    CHECK(!oversized.get());

    broker.Forget();
    CHECK(!broker.Authorized(product));
    CHECK(Next(broker, request, Kind::Release));
}

void TouchNotificationsAndWake() {
    std::atomic<int> wakes{0};
    Broker broker(10);
    broker.Touch(true);
    broker.SetWake([&] { ++wakes; });
    CHECK(wakes.load() == 1);
    broker.Touch(false);
    Request request;
    CHECK(broker.Poll(request) && request.kind == Kind::Touch && request.operation == 0);
    CHECK(!broker.Poll(request));
    const int before = wakes.load();
    auto confirm = std::async(std::launch::async, [&] { return broker.Confirm("webauthn.io", 2); });
    CHECK(Next(broker, request, Kind::Confirm));
    CHECK(wakes.load() > before);
    CHECK(broker.Respond(request.id, Ok()));
    CHECK(confirm.get());
}

void CloseFailsEverything() {
    Broker broker(11);
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker.Select(name);
    });
    Request request;
    CHECK(Next(broker, request, Kind::Select));
    CHECK(broker.Respond(request.id, Ok("Key")));
    CHECK(select.get());
    auto read = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return broker.ReadReport(report, 4000);
    });
    CHECK(Next(broker, request, Kind::Read));
    broker.Close();
    CHECK(read.wait_for(1s) == std::future_status::ready);
    CHECK(!read.get());
    CHECK(broker.Closed());
    CHECK(!broker.Begin());
    CHECK(!broker.Confirm("webauthn.io", 1));
    std::array<uint8_t, 64> report{};
    CHECK(!broker.WriteReport(report));
    std::string product;
    CHECK(!broker.Authorized(product));
    CHECK(Next(broker, request, Kind::Release));
}

void Registry() {
    int first = 0;
    int second = 0;
    auto a = Attach(&first, 21);
    CHECK(a && ForContext(&first) == a && ForSession(21) == a);
    CHECK(!Attach(nullptr, 21) && !Attach(&first, 0));
    // Reconnect: a new context for the same session before the old one is detached.
    auto b = Attach(&second, 21);
    Close(&first);
    CHECK(ForSession(21) == b);
    Detach(&first);
    CHECK(ForContext(&first) == nullptr);
    Detach(&second);
    CHECK(b->Closed());
    CHECK(ForSession(21) == nullptr);
}
} // namespace

int main() {
    ConfirmRoundTrip();
    CancelEndsUserPromptsButNotIo();
    SelectPinAndReports();
    TouchNotificationsAndWake();
    CloseFailsEverything();
    Registry();
    if (failures != 0) {
        std::fprintf(stderr, "%d broker check(s) failed\n", failures);
        return 1;
    }
    std::printf("PASS RDP security-key broker: prompts, cancellation, close, reports, notifications, registry\n");
    return 0;
}

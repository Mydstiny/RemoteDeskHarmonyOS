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

// Polls the session until a request of the given kind arrives (or 2 s pass); other kinds are skipped.
bool Next(uint64_t session, Request& request, Kind kind) {
    for (int i = 0; i < 400; ++i) {
        if (Poll(session, request)) {
            if (request.kind == kind) return true;
            continue;
        }
        std::this_thread::sleep_for(5ms);
    }
    return false;
}

// The worker wakes the watcher just after the request becomes pollable; give that callback a moment.
template <typename Condition>
bool Eventually(Condition condition) {
    for (int i = 0; i < 400; ++i) {
        if (condition()) return true;
        std::this_thread::sleep_for(5ms);
    }
    return condition();
}

Reply Ok(const std::string& text = "") {
    Reply reply;
    reply.ok = true;
    reply.text = text;
    return reply;
}

struct Context {
    int value = 0;
};

void ConfirmRoundTrip() {
    Context context;
    auto broker = Attach(&context, 7);
    CHECK(broker && Watch(7, nullptr));
    CHECK(broker->Begin());
    auto accepted = std::async(std::launch::async, [&] { return broker->Confirm("webauthn.io", 1); });
    Request request;
    CHECK(Next(7, request, Kind::Confirm));
    CHECK(request.text == "webauthn.io");
    CHECK(request.operation == 1);
    CHECK(!Respond(7, request.id + 1, Ok()));
    CHECK(!Respond(8, request.id, Ok()));
    CHECK(Respond(7, request.id, Ok()));
    CHECK(!Respond(7, request.id, Ok()));
    CHECK(accepted.get());

    auto rejected = std::async(std::launch::async, [&] { return broker->Confirm("github.com", 2); });
    CHECK(Next(7, request, Kind::Confirm));
    Reply no;
    CHECK(Respond(7, request.id, no));
    CHECK(!rejected.get());
    // An answered prompt is never dismissed.
    CHECK(!Poll(7, request));

    CHECK(!broker->Confirm("", 1));
    CHECK(!broker->Confirm("example.com", 3));
    CHECK(SanitizeRpId(std::string("bad\x01host\xe4 x", 10)) == "bad?host??");
    CHECK(SanitizeRpId(std::string(400, 'a')).size() == kMaxRpIdLength);
    Unwatch(7);
    Detach(&context);
}

void CancelDismissesPromptsButNotIo() {
    // Declared before the broker: detaching closes it, which reports the cancellation.
    std::atomic<bool> eventCancelled{false};
    Context context;
    auto broker = Attach(&context, 8);
    CHECK(Watch(8, nullptr));
    broker->OnCancelChanged([&](bool cancelled) { eventCancelled = cancelled; });
    CHECK(broker->Begin());
    auto confirm = std::async(std::launch::async, [&] { return broker->Confirm("webauthn.io", 1); });
    Request request;
    CHECK(Next(8, request, Kind::Confirm));
    const uint32_t shown = request.id;
    Cancel(8);
    CHECK(eventCancelled.load());
    CHECK(confirm.wait_for(1s) == std::future_status::ready);
    CHECK(!confirm.get());
    CHECK(!Respond(8, shown, Ok()));
    // The prompt ArkTS is showing has to come down.
    CHECK(Poll(8, request) && request.kind == Kind::Dismiss && request.id == shown);
    // While cancelled, prompts fail immediately but device I/O (the CTAPHID_CANCEL write) still goes through.
    CHECK(!broker->Pin(3).has_value());
    auto write = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        report[4] = 0x91;
        return broker->WriteReport(report);
    });
    CHECK(Next(8, request, Kind::Write));
    CHECK(request.report[4] == 0x91);
    CHECK(Respond(8, request.id, Ok()));
    CHECK(write.get());
    // An undelivered request that ends is not dismissed: nothing was shown.
    CHECK(broker->Begin());
    CHECK(!eventCancelled.load());
    broker->Cancel();
    std::string ignored;
    CHECK(broker->Select(ignored) == Authenticator::None);
    CHECK(!Poll(8, request));
    broker->OnCancelChanged(nullptr);
    Unwatch(8);
    Detach(&context);
}

void SelectPinAndReports() {
    Context context;
    auto broker = Attach(&context, 9);
    CHECK(Watch(9, nullptr));
    std::string product;
    CHECK(broker->Authorized(product) == Authenticator::None);
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name) == Authenticator::UsbKey ? name : std::string("<none>");
    });
    Request request;
    CHECK(Next(9, request, Kind::Select));
    CHECK(Respond(9, request.id, Ok("Key\x07 \x1b[31m5C")));
    CHECK(select.get() == "Key [31m5C");
    CHECK(broker->Authorized(product) == Authenticator::UsbKey && product == "Key [31m5C");

    auto pin = std::async(std::launch::async, [&] { return broker->Pin(5); });
    CHECK(Next(9, request, Kind::Pin));
    CHECK(request.retries == 5);
    CHECK(Respond(9, request.id, Ok("123456")));
    const auto entered = pin.get();
    CHECK(entered.has_value() && *entered == "123456");

    // Each invalid PIN is refused locally, so it never costs a retry on the key.
    for (const std::string& invalid : {std::string("123"), std::string("12\0" "34", 5),
                                       std::string(kMaxPinBytes + 1, '1'), std::string("12\xff" "45")}) {
        auto refused = std::async(std::launch::async, [&] { return broker->Pin(-1); });
        CHECK(Next(9, request, Kind::Pin));
        CHECK(Respond(9, request.id, Ok(invalid)));
        CHECK(!refused.get().has_value());
    }
    auto unicode = std::async(std::launch::async, [&] { return broker->Pin(-1); });
    CHECK(Next(9, request, Kind::Pin));
    CHECK(Respond(9, request.id, Ok("密钥口令")));
    CHECK(unicode.get() == std::optional<std::string>("密钥口令"));

    auto read = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return broker->ReadReport(report, 100000) ? report[7] : 0;
    });
    CHECK(Next(9, request, Kind::Read));
    CHECK(request.timeoutMs == kMaxReadMs);
    Reply data = Ok();
    data.report[4] = 0x90;
    data.report[5] = 0x00;
    data.report[6] = 0x10;
    data.report[7] = 0x42;
    CHECK(Respond(9, request.id, data));
    CHECK(read.get() == 0x42);

    auto oversized = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return broker->ReadReport(report, 50);
    });
    CHECK(Next(9, request, Kind::Read));
    CHECK(request.timeoutMs == 50);
    data.report[5] = 0x1d;  // 7614 > 7609
    data.report[6] = 0xbe;
    CHECK(Respond(9, request.id, data));
    CHECK(!oversized.get());

    broker->Forget();
    CHECK(broker->Authorized(product) == Authenticator::None);
    CHECK(Next(9, request, Kind::Release));
    Unwatch(9);
    Detach(&context);
}

void LabelsAndPins() {
    // Printable, valid UTF-8 only; never cut inside a character.
    CHECK(SanitizeLabel("YubiKey\t5\x7f", 63) == "YubiKey5");
    CHECK(SanitizeLabel(std::string("ab\xc0\x80" "cd\xed\xa0\x80" "e\xf8"), 63) == "abcde");
    CHECK(SanitizeLabel("\xc2\x85" "x", 63) == "x");
    CHECK(SanitizeLabel("安全密钥", 7) == "安全");
    CHECK(SanitizeLabel(std::string(70, 'k'), kMaxProductBytes).size() == kMaxProductBytes);
    // A CJK key name of 80 characters (240 bytes) fits the reply limit and is cut to 21 whole characters.
    std::string longName;
    for (int i = 0; i < 80; ++i) longName += "密";
    CHECK(longName.size() <= kMaxReplyTextBytes);
    CHECK(SanitizeLabel(longName, kMaxProductBytes) == longName.substr(0, 63));
    CHECK(ValidPin("1234"));
    CHECK(ValidPin("密钥口令"));
    CHECK(!ValidPin("密钥口"));
    CHECK(!ValidPin(""));
    CHECK(!ValidPin(std::string(64, 'a')));
    CHECK(ValidPin(std::string(63, 'a')));
}

void TouchNotificationsAndWake() {
    std::atomic<int> wakes{0};
    Context context;
    auto broker = Attach(&context, 10);
    broker->Touch(true);
    // A notification owed before ArkTS watches wakes it as soon as it does.
    CHECK(Watch(10, [&] { ++wakes; }));
    CHECK(wakes.load() == 1);
    broker->Touch(false);
    CHECK(wakes.load() == 2);
    Request request;
    CHECK(Poll(10, request) && request.kind == Kind::Touch && request.operation == 0);
    CHECK(!Poll(10, request));
    const int before = wakes.load();
    auto confirm = std::async(std::launch::async, [&] { return broker->Confirm("webauthn.io", 2); });
    CHECK(Next(10, request, Kind::Confirm));
    CHECK(Eventually([&] { return wakes.load() > before; }));
    CHECK(Respond(10, request.id, Ok()));
    CHECK(confirm.get());
    Unwatch(10);
    const int unwatched = wakes.load();
    broker->Touch(true);
    CHECK(wakes.load() == unwatched);
    Detach(&context);
    CHECK(!Watch(10, nullptr));
}

void PollOrder() {
    Context context;
    auto broker = Attach(&context, 12);
    CHECK(Watch(12, nullptr));
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name) == Authenticator::UsbKey;
    });
    Request request;
    CHECK(Next(12, request, Kind::Select));
    CHECK(Respond(12, request.id, Ok("Key")));
    CHECK(select.get());
    // The key fails to open: ArkTS must release it before it sees the next Select of the same request.
    broker->Forget();
    broker->Touch(true);
    auto again = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name) == Authenticator::UsbKey;
    });
    for (int i = 0; i < 400 && !broker->HasUndelivered(); ++i) std::this_thread::sleep_for(5ms);
    CHECK(Poll(12, request) && request.kind == Kind::Release);
    CHECK(Poll(12, request) && request.kind == Kind::Select);
    const uint32_t selectId = request.id;
    CHECK(Poll(12, request) && request.kind == Kind::Touch && request.operation == 1);
    CHECK(!Poll(12, request));
    Cancel(12);
    CHECK(!again.get());
    CHECK(Poll(12, request) && request.kind == Kind::Dismiss && request.id == selectId);
    Unwatch(12);
    Detach(&context);
}

void CloseFailsEverythingAndReleasesThroughTheSession() {
    Context context;
    auto broker = Attach(&context, 11);
    CHECK(Watch(11, nullptr));
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name) == Authenticator::UsbKey;
    });
    Request request;
    CHECK(Next(11, request, Kind::Select));
    CHECK(Respond(11, request.id, Ok("Key")));
    CHECK(select.get());
    auto read = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return broker->ReadReport(report, 4000);
    });
    CHECK(Next(11, request, Kind::Read));
    Close(&context);
    CHECK(read.wait_for(1s) == std::future_status::ready);
    CHECK(!read.get());
    CHECK(broker->Closed());
    CHECK(!broker->Begin());
    CHECK(!broker->Confirm("webauthn.io", 1));
    std::array<uint8_t, 64> report{};
    CHECK(!broker->WriteReport(report));
    std::string product;
    CHECK(broker->Authorized(product) == Authenticator::None);
    // No open broker is left, yet the key ArkTS holds is still released.
    CHECK(ForSession(11) == nullptr);
    CHECK(Poll(11, request) && request.kind == Kind::Release);
    CHECK(!Poll(11, request));
    Unwatch(11);
    Detach(&context);
}

void ReconnectKeepsTheWatcherAndIds() {
    std::atomic<int> wakes{0};
    Context first;
    Context second;
    auto a = Attach(&first, 21);
    CHECK(a && ForContext(&first) == a && ForSession(21) == a && ForGeneration(a->Generation()) == a);
    CHECK(!Attach(nullptr, 21) && !Attach(&first, 0));
    CHECK(Watch(21, [&] { ++wakes; }));
    auto readA = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return a->ReadReport(report, 4000);
    });
    Request request;
    CHECK(Next(21, request, Kind::Read));
    const uint32_t staleId = request.id;
    // Network recovery: the old connection closes and detaches, a new one attaches for the same session.
    Close(&first);
    CHECK(!readA.get());
    Detach(&first);
    CHECK(ForContext(&first) == nullptr);
    auto b = Attach(&second, 21);
    CHECK(b->Generation() != a->Generation());
    CHECK(ForGeneration(a->Generation()) == nullptr);
    const int before = wakes.load();
    auto readB = std::async(std::launch::async, [&] {
        std::array<uint8_t, 64> report{};
        return b->ReadReport(report, 4000) ? report[0] : 0;
    });
    CHECK(Next(21, request, Kind::Read));
    CHECK(Eventually([&] { return wakes.load() > before; }));
    // A late answer to the old connection's read never lands on the new one.
    CHECK(request.id != staleId);
    Reply stale = Ok();
    stale.report[0] = 0xee;
    CHECK(!Respond(21, staleId, stale));
    Reply fresh = Ok();
    fresh.report[0] = 0x42;
    CHECK(Respond(21, request.id, fresh));
    CHECK(readB.get() == 0x42);
    Unwatch(21);
    Detach(&second);
    CHECK(b->Closed());
    CHECK(ForSession(21) == nullptr);
}

void ReleasedForgetsTheKey() {
    Context context;
    auto broker = Attach(&context, 31);
    CHECK(Watch(31, nullptr));
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name) == Authenticator::UsbKey;
    });
    Request request;
    CHECK(Next(31, request, Kind::Select));
    CHECK(Respond(31, request.id, Ok("Key")));
    CHECK(select.get());
    Released(31);
    std::string product;
    CHECK(broker->Authorized(product) == Authenticator::None);
    CHECK(!Poll(31, request));
    Unwatch(31);
    Detach(&context);
}

void PhonePasskey() {
    Context context;
    auto broker = Attach(&context, 51);
    CHECK(Watch(51, nullptr));
    CHECK(broker->Begin(60000));
    // The user picks the phone: remembered for the session, and nothing is held that would need a release.
    auto select = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name);
    });
    Request request;
    CHECK(Next(51, request, Kind::Select));
    Reply phone = Ok("Phone passkey");
    phone.authenticator = Authenticator::Phone;
    CHECK(Respond(51, request.id, phone));
    CHECK(select.get() == Authenticator::Phone);
    std::string product;
    CHECK(broker->Authorized(product) == Authenticator::Phone && product == "Phone passkey");
    // A CTAP command goes to ArkTS with the confirmed relying party and the time the phone may take; the phone's
    // CTAP response comes back as is.
    const std::vector<uint8_t> command{0x02, 0xa1, 0x01, 0x6a, 'g', 'i', 't', 'h', 'u', 'b', '.', 'c', 'o', 'm'};
    auto passkey = std::async(std::launch::async, [&] { return broker->Passkey(command, "github.com"); });
    CHECK(Next(51, request, Kind::Passkey));
    CHECK(request.payload == command);
    CHECK(request.text == "github.com");
    CHECK(request.timeoutMs > 0 && request.timeoutMs <= kMaxPhoneRequestMs);
    Reply answer = Ok("ignored");
    answer.payload = {0x00, 0xa1, 0x01, 0x02};
    CHECK(Respond(51, request.id, answer));
    const auto response = passkey.get();
    CHECK(response.has_value() && *response == std::vector<uint8_t>({0x00, 0xa1, 0x01, 0x02}));
    // An empty or oversized response is refused; a cancelled request comes back empty.
    auto empty = std::async(std::launch::async, [&] { return broker->Passkey(command, "github.com"); });
    CHECK(Next(51, request, Kind::Passkey));
    CHECK(Respond(51, request.id, Ok()));
    CHECK(!empty.get().has_value());
    auto oversized = std::async(std::launch::async, [&] { return broker->Passkey(command, "github.com"); });
    CHECK(Next(51, request, Kind::Passkey));
    Reply big = Ok();
    big.payload.assign(kMaxPasskeyReplyBytes + 1, 0);
    CHECK(Respond(51, request.id, big));
    CHECK(!oversized.get().has_value());
    auto cancelled = std::async(std::launch::async, [&] { return broker->Passkey(command, "github.com"); });
    CHECK(Next(51, request, Kind::Passkey));
    const uint32_t shown = request.id;
    Cancel(51);
    CHECK(!cancelled.get().has_value());
    CHECK(Poll(51, request) && request.kind == Kind::Dismiss && request.id == shown);
    // Too short or too long a command never reaches ArkTS; a relying party is shown escaped and bounded.
    CHECK(broker->Begin(60000));
    CHECK(!broker->Passkey(std::vector<uint8_t>(1, 0x01), "github.com").has_value());
    CHECK(!broker->Passkey(std::vector<uint8_t>(kMaxPasskeyRequestBytes + 1, 0x01), "github.com").has_value());
    CHECK(!Poll(51, request));
    auto escaped = std::async(std::launch::async, [&] { return broker->Passkey(command, "evil\ncom"); });
    CHECK(Next(51, request, Kind::Passkey));
    CHECK(request.text == "evil?com");
    CHECK(Respond(51, request.id, Reply{}));
    CHECK(!escaped.get().has_value());
    // Without a remote deadline the phone may take its own limit.
    CHECK(broker->Begin(0));
    auto unbounded = std::async(std::launch::async, [&] { return broker->Passkey(command, "github.com"); });
    CHECK(Next(51, request, Kind::Passkey));
    CHECK(request.timeoutMs == kMaxPhoneRequestMs);
    CHECK(Respond(51, request.id, Reply{}));
    CHECK(!unbounded.get().has_value());
    // ArkTS released the phone (Released, as when it cannot answer): the session asks for an authenticator again.
    Released(51);
    CHECK(broker->Authorized(product) == Authenticator::None);
    CHECK(!Poll(51, request));
    // Forgetting a phone choice owes ArkTS no release.
    CHECK(broker->Begin(60000));
    auto again = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name);
    });
    CHECK(Next(51, request, Kind::Select));
    CHECK(Respond(51, request.id, phone));
    CHECK(again.get() == Authenticator::Phone);
    broker->Forget();
    CHECK(broker->Authorized(product) == Authenticator::None);
    CHECK(!Poll(51, request));
    // A Select answer naming no known authenticator is a refusal.
    CHECK(broker->Begin());
    auto unknown = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name);
    });
    CHECK(Next(51, request, Kind::Select));
    Reply odd = Ok("x");
    odd.authenticator = Authenticator::None;
    CHECK(Respond(51, request.id, odd));
    CHECK(unknown.get() == Authenticator::None);
    // Closing a session whose phone was chosen owes ArkTS no release either.
    CHECK(broker->Begin(60000));
    auto last = std::async(std::launch::async, [&] {
        std::string name;
        return broker->Select(name);
    });
    CHECK(Next(51, request, Kind::Select));
    CHECK(Respond(51, request.id, phone));
    CHECK(last.get() == Authenticator::Phone);
    Close(&context);
    CHECK(!Poll(51, request));
    Unwatch(51);
    Detach(&context);
}

void Deadlines() {
    Context context;
    auto broker = Attach(&context, 41);
    CHECK(broker->Begin(0));
    CHECK(broker->RemainingMs() == kNoDeadline);
    CHECK(broker->Begin(1));
    CHECK(broker->RemainingMs() > kMinRequestMs - 1000 && broker->RemainingMs() <= kMinRequestMs);
    CHECK(broker->Begin(UINT32_MAX - 1));
    CHECK(broker->RemainingMs() <= kMaxRequestMs && broker->RemainingMs() > kMaxRequestMs - 1000);
    CHECK(broker->Begin(15000));
    CHECK(broker->RemainingMs() <= 15000 && broker->RemainingMs() > 14000);
    Detach(&context);
    CHECK(!broker->Begin(15000));
}
} // namespace

int main() {
    ConfirmRoundTrip();
    CancelDismissesPromptsButNotIo();
    SelectPinAndReports();
    LabelsAndPins();
    TouchNotificationsAndWake();
    PollOrder();
    CloseFailsEverythingAndReleasesThroughTheSession();
    ReconnectKeepsTheWatcherAndIds();
    ReleasedForgetsTheKey();
    PhonePasskey();
    Deadlines();
    if (failures != 0) {
        std::fprintf(stderr, "%d broker check(s) failed\n", failures);
        return 1;
    }
    std::printf("PASS RDP security-key broker: prompts, dismiss, cancellation, close, reconnect, request IDs, "
                "poll order, PIN and label rules, phone passkey, deadlines\n");
    return 0;
}

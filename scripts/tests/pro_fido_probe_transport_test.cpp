#include "fido_probe_transport.h"
#include <cbor.h>
#include <algorithm>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using namespace ProFido;
using namespace std::chrono_literals;
using Report = std::array<uint8_t, 64>;
std::atomic<size_t> maximumCborAllocation{0};
void RecordAllocation(size_t size) {
    size_t previous = maximumCborAllocation.load();
    while (previous < size && !maximumCborAllocation.compare_exchange_weak(previous, size)) {}
}
// Test-only hooks refuse unsafe allocations rather than reproducing an OOM.
void* BoundedMalloc(size_t size) {
    RecordAllocation(size); return size > 1048576 ? nullptr : std::malloc(size);
}
void* BoundedRealloc(void* pointer, size_t size) {
    RecordAllocation(size); return size > 1048576 ? nullptr : std::realloc(pointer, size);
}
void Check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

std::deque<Report> Frames(uint32_t cid, uint8_t command, const std::vector<uint8_t>& payload) {
    std::deque<Report> result;
    size_t offset = 0;
    uint8_t sequence = 0;
    do {
        Report frame{};
        frame[0] = cid >> 24; frame[1] = cid >> 16; frame[2] = cid >> 8; frame[3] = cid;
        const size_t header = result.empty() ? 7 : 5;
        if (result.empty()) { frame[4] = command; frame[5] = payload.size() >> 8; frame[6] = payload.size(); }
        else frame[4] = sequence++;
        const auto count = std::min(payload.size() - offset, frame.size() - header);
        std::copy_n(payload.data() + offset, count, frame.data() + header);
        offset += count;
        result.push_back(frame);
    } while (offset < payload.size());
    return result;
}

std::vector<uint8_t> Info(bool fragmented, bool emptyVersions) {
    // CTAP success; canonical CBOR {1:["FIDO_2_0"], 3:h'0000...'}.
    std::vector<uint8_t> result{0, uint8_t(fragmented ? 0xa3 : 0xa2), 1, uint8_t(emptyVersions ? 0x80 : 0x81)};
    if (!emptyVersions) {
        result.push_back(0x68);
        for (char value : std::string("FIDO_2_0")) result.push_back(value);
    }
    if (fragmented) {
        // GetInfo extensions, long enough to require a HID continuation frame.
        result.push_back(2); result.push_back(0x81); result.push_back(0x78); result.push_back(80);
        result.resize(result.size() + 80, 'a');
    }
    result.push_back(3); result.push_back(0x50); result.resize(result.size() + 16);
    return result;
}

ProbeStatus Run(const std::string& scenario) {
    ProbeTransport probe(500ms);
    std::deque<Report> incoming;
    unsigned writes = 0;
    uint32_t priorRequest = 0;
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < deadline) {
        const auto snapshot = probe.Poll();
        if (snapshot.status != ProbeStatus::Running) {
            Check(writes <= 3, "command budget exceeded");
            if (snapshot.status == ProbeStatus::Success) Check(writes == 3, "missing explicit GetInfo");
            return snapshot.status;
        }
        const auto& request = snapshot.request;
        if (request.id == 0) { std::this_thread::sleep_for(100us); continue; }
        Check(request.id > priorRequest, "request IDs must increase");
        Check(request.timeoutMs > 0 && request.timeoutMs <= 1500, "unbounded USB timeout");
        Check(probe.Poll().request.id == 0, "a request must be delivered once");
        Check(!probe.Reply(request.id + 1, request.report.data(), 64, true), "foreign request accepted");
        if (priorRequest) Check(!probe.Reply(priorRequest, request.report.data(), 64, true), "late reply accepted");
        priorRequest = request.id;
        if (!request.write && writes == 2 && incoming.size() == 1 &&
            (scenario == "cancel-fragment" || scenario == "timeout-fragment")) {
            if (scenario == "cancel-fragment") probe.Cancel();
            else std::this_thread::sleep_for(600ms);
            Check(!probe.Reply(request.id, request.report.data(), 64, true), "expired fragment reply accepted");
            continue;
        }
        if (scenario == "cancel") {
            probe.Cancel();
            Check(!probe.Reply(request.id, request.report.data(), 64, true), "cancelled reply accepted");
            continue;
        }
        Report reply = request.report;
        if (request.write) {
            ++writes;
            if (writes == 1) {
                Check(reply[4] == 0x86 && reply[5] == 0 && reply[6] == 8, "only INIT may open");
                std::vector<uint8_t> init(reply.begin() + 7, reply.begin() + 15);
                init.insert(init.end(), {0x10, 0x20, 0x30, 0x40, 2, 1, 0, 0, 4});
                if (scenario == "wrong-nonce") init[0] ^= 1;
                if (scenario == "zero-channel") std::fill(init.begin() + 8, init.begin() + 12, 0);
                if (scenario == "broadcast-channel") std::fill(init.begin() + 8, init.begin() + 12, 255);
                if (scenario == "old-protocol") init[12] = 1;
                if (scenario == "no-cbor") init[16] = 0;
                incoming = Frames(UINT32_MAX, 0x86, init);
                if (scenario == "foreign-channel") incoming.push_front(Frames(9, 0x86, init).front());
            } else {
                Check(reply[0] == 0x10 && reply[1] == 0x20 && reply[2] == 0x30 && reply[3] == 0x40,
                      "GetInfo must use the allocated channel");
                Check(reply[4] == 0x90 && reply[5] == 0 && reply[6] == 1 && reply[7] == 4,
                      "unexpected non-capability command");
                auto payload = Info(scenario == "fragmented" || scenario == "bad-sequence" ||
                    scenario == "cancel-fragment" || scenario == "timeout-fragment", scenario == "empty-versions");
                if (scenario == "malformed-cbor") payload = {0, 0xff};
                if (scenario == "huge-array" || (scenario == "huge-array-second" && writes == 3))
                    payload = {0, 0xa1, 1, 0x9a, 0x40, 0, 0, 0};
                if (scenario == "huge-map") payload = {0, 0xba, 0x40, 0, 0, 0};
                if (scenario == "huge-string") payload = {0, 0xa1, 1, 0x7a, 0x40, 0, 0, 0};
                if (scenario == "huge-bytes") payload = {0, 0xa1, 3, 0x5a, 0x40, 0, 0, 0};
                if (scenario == "deep-tree") {
                    payload = {0, 0xa1, 0x18, 32}; payload.insert(payload.end(), 10, 0x81); payload.push_back(0);
                }
                if (scenario == "node-budget") {
                    payload = {0, 0xa1, 0x18, 32, 0x98, 64};
                    for (unsigned i = 0; i < 64; ++i) { payload.push_back(0x88); payload.insert(payload.end(), 8, 0); }
                }
                if (scenario == "indefinite") payload = {0, 0xbf, 1, 0x9f, 0xff, 0xff};
                if (scenario == "trailing-cbor") payload.push_back(0);
                if (scenario == "ctap-error") payload = {0x2e};
                incoming = Frames(0x10203040, 0x90, payload);
                if (scenario == "oversized") { incoming.front()[5] = 255; incoming.front()[6] = 255; }
                if (scenario == "bad-sequence") incoming[1][4] = 1;
                if (scenario == "keepalive") incoming.push_front(Frames(0x10203040, 0xbb, {1}).front());
            }
            if (scenario == "changed-write") reply[0] ^= 1;
        } else {
            Check(!incoming.empty(), "unexpected library read");
            reply = incoming.front(); incoming.pop_front();
        }
        const bool fail = scenario == "usb-error";
        Check(probe.Reply(request.id, reply.data(), scenario == "short-report" ? 63 : 64, !fail),
              "current reply rejected");
        // Duplicate replies cannot resolve a later request even if the worker advances.
        Check(!probe.Reply(request.id, reply.data(), 64, true), "duplicate reply accepted");
    }
    throw std::runtime_error("worker did not terminate within bound");
}

int main() {
    cbor_set_allocs(BoundedMalloc, BoundedRealloc, std::free);
    try {
        unsigned count = 0;
        for (const auto* scenario : {"normal", "fragmented", "keepalive", "foreign-channel"}) {
            Check(Run(scenario) == ProbeStatus::Success, scenario); ++count;
        }
        for (const auto* scenario : {"wrong-nonce", "zero-channel", "broadcast-channel", "old-protocol", "no-cbor",
                "empty-versions", "malformed-cbor", "ctap-error", "oversized", "bad-sequence", "changed-write",
                "short-report", "usb-error", "huge-array", "huge-array-second", "huge-map", "huge-string",
                "huge-bytes", "deep-tree", "node-budget", "indefinite", "trailing-cbor", "timeout-fragment"}) {
            Check(Run(scenario) == ProbeStatus::Failed, scenario); ++count;
        }
        Check(Run("cancel") == ProbeStatus::Cancelled, "cancel"); ++count;
        Check(Run("cancel-fragment") == ProbeStatus::Cancelled, "cancel-fragment"); ++count;
        {
            ProbeTransport ignored(15ms);
            std::this_thread::sleep_for(30ms);
            Check(ignored.Poll().status == ProbeStatus::Failed, "unpolled timeout"); ++count;
        }
        {
            const auto started = std::chrono::steady_clock::now();
            auto waiting = std::make_unique<ProbeTransport>();
            while (waiting->Poll().request.id == 0) std::this_thread::sleep_for(100us);
            waiting.reset();
            Check(std::chrono::steady_clock::now() - started < 1s, "cleanup depended on a JS callback"); ++count;
        }
        Check(maximumCborAllocation.load() <= 1048576, "unbounded CBOR declaration reached the allocator");
        std::cout << "PASS " << count << " real-libfido2 transport cases; maximum CBOR allocation "
                  << maximumCborAllocation.load() << " bytes (no hardware acceptance)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}

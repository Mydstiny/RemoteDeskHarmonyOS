#include "test_runner.h"
#include "extensions/session_clipboard_authority.h"

#include <atomic>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
bool Alive(int32_t, uint64_t) { return true; }
}

RDP_TEST_CASE(clipboard_authority_invalid_identity_never_acquires) {
    SessionClipboardAuthority owner;
    for (int32_t sid : {0, -1}) { RDP_ASSERT_EQ(owner.claim(sid, 1, false, Alive), 0u); }
    RDP_ASSERT_EQ(owner.claim(1, 0, false, Alive), 0u);
    RDP_ASSERT_EQ(owner.claim(1, SessionClipboardAuthority::kMaxSafeInteger + 1, false, Alive), 0u);
    RDP_ASSERT(!owner.owns(1, 1, 0, Alive));
    RDP_ASSERT(owner.claim(1, 1, false, Alive) > 0);
}

RDP_TEST_CASE(clipboard_authority_automatic_claim_never_replaces_live_owner_even_same_session) {
    SessionClipboardAuthority owner;
    const auto token = owner.claim(7, 11, false, Alive);
    RDP_ASSERT(token > 0);
    RDP_ASSERT_EQ(owner.claim(8, 12, false, Alive), 0u);
    RDP_ASSERT_EQ(owner.claim(7, 11, false, Alive), 0u);
    RDP_ASSERT(owner.owns(7, 11, token, Alive));
}

RDP_TEST_CASE(clipboard_authority_explicit_replace_invalidates_every_old_identity) {
    SessionClipboardAuthority owner;
    const auto old = owner.claim(7, 11, false, Alive);
    const auto next = owner.claim(8, 12, true, Alive);
    RDP_ASSERT(next > old);
    RDP_ASSERT(!owner.owns(7, 11, old, Alive));
    RDP_ASSERT(!owner.owns(8, 11, next, Alive));
    RDP_ASSERT(!owner.owns(7, 12, next, Alive));
    RDP_ASSERT(!owner.owns(8, 12, old, Alive));
    RDP_ASSERT(!owner.revoke(7, 11, old, Alive));
    RDP_ASSERT(owner.owns(8, 12, next, Alive));
}

RDP_TEST_CASE(clipboard_authority_same_session_explicit_reauthorization_never_reuses_token) {
    SessionClipboardAuthority owner;
    const auto first = owner.claim(7, 11, false, Alive);
    const auto second = owner.claim(7, 11, true, Alive);
    RDP_ASSERT(second > first);
    RDP_ASSERT(!owner.owns(7, 11, first, Alive));
    RDP_ASSERT(owner.revoke(7, 11, second, Alive));
    RDP_ASSERT(!owner.revoke(7, 11, second, Alive));
    const auto third = owner.claim(7, 11, false, Alive);
    RDP_ASSERT(third > second);
}

RDP_TEST_CASE(clipboard_authority_dead_generation_is_retired_before_idle_claim) {
    SessionClipboardAuthority owner;
    uint64_t generation = 11;
    const auto alive = [&generation](int32_t sid, uint64_t gen) { return sid == 7 && gen == generation; };
    const auto first = owner.claim(7, 11, false, alive);
    generation = 12;
    RDP_ASSERT(!owner.owns(7, 11, first, alive));
    const auto second = owner.claim(7, 12, false, alive);
    RDP_ASSERT(second > first);
    RDP_ASSERT(!owner.revoke(7, 11, first, alive));
    RDP_ASSERT(owner.owns(7, 12, second, alive));
}

RDP_TEST_CASE(clipboard_authority_failed_replacement_does_not_displace_live_target) {
    SessionClipboardAuthority owner;
    const auto alive = [](int32_t sid, uint64_t gen) { return sid == 7 && gen == 11; };
    const auto token = owner.claim(7, 11, false, alive);
    RDP_ASSERT_EQ(owner.claim(8, 12, true, alive), 0u);
    RDP_ASSERT_EQ(owner.claim(-1, 11, true, alive), 0u);
    RDP_ASSERT(owner.owns(7, 11, token, alive));
}

RDP_TEST_CASE(clipboard_authority_validator_exception_is_fail_closed_and_not_a_deadlock) {
    SessionClipboardAuthority owner;
    const auto token = owner.claim(7, 11, false, Alive);
    const auto throwing = [](int32_t, uint64_t) -> bool { throw std::runtime_error("validator unavailable"); };
    RDP_ASSERT(!owner.owns(7, 11, token, throwing));
    RDP_ASSERT_EQ(owner.claim(8, 12, false, throwing), 0u);
    const auto next = owner.claim(8, 12, false, Alive);
    RDP_ASSERT(next > token);
    RDP_ASSERT(!owner.owns(7, 11, token, Alive));
}

RDP_TEST_CASE(clipboard_authority_token_exhaustion_never_wraps_or_replaces_live_owner) {
    SessionClipboardAuthority owner(SessionClipboardAuthority::kMaxSafeInteger - 1);
    const auto token = owner.claim(7, 11, false, Alive);
    RDP_ASSERT_EQ(token, SessionClipboardAuthority::kMaxSafeInteger);
    RDP_ASSERT_EQ(owner.claim(8, 12, true, Alive), 0u);
    RDP_ASSERT(owner.owns(7, 11, token, Alive));
    RDP_ASSERT(owner.revoke(7, 11, token, Alive));
    RDP_ASSERT_EQ(owner.claim(7, 11, false, Alive), 0u);
}

RDP_TEST_CASE(clipboard_authority_concurrent_idle_claims_have_exactly_one_winner) {
    SessionClipboardAuthority owner;
    constexpr size_t count = 24;
    std::atomic<bool> start {false};
    std::vector<uint64_t> tokens(count);
    std::vector<std::thread> workers;
    for (size_t i = 0; i < count; ++i) {
        workers.emplace_back([&, i] {
            while (!start.load(std::memory_order_acquire)) { std::this_thread::yield(); }
            tokens[i] = owner.claim(static_cast<int32_t>(i + 1), 1, false, Alive);
        });
    }
    start.store(true, std::memory_order_release);
    for (auto& worker : workers) { worker.join(); }
    size_t winners = 0;
    for (size_t i = 0; i < count; ++i) {
        if (tokens[i] > 0) {
            ++winners;
            RDP_ASSERT(owner.owns(static_cast<int32_t>(i + 1), 1, tokens[i], Alive));
        }
    }
    RDP_ASSERT_EQ(winners, 1u);
}

RDP_TEST_CASE(clipboard_authority_concurrent_explicit_handoffs_issue_unique_tokens_and_one_owner) {
    SessionClipboardAuthority owner;
    constexpr size_t count = 24;
    std::vector<uint64_t> tokens(count);
    std::vector<std::thread> workers;
    for (size_t i = 0; i < count; ++i) {
        workers.emplace_back([&, i] { tokens[i] = owner.claim(static_cast<int32_t>(i + 1), 1, true, Alive); });
    }
    for (auto& worker : workers) { worker.join(); }
    size_t winners = 0;
    for (size_t i = 0; i < count; ++i) {
        RDP_ASSERT(tokens[i] > 0);
        for (size_t j = i + 1; j < count; ++j) { RDP_ASSERT(tokens[i] != tokens[j]); }
        if (owner.owns(static_cast<int32_t>(i + 1), 1, tokens[i], Alive)) { ++winners; }
    }
    RDP_ASSERT_EQ(winners, 1u);
}

RDP_TEST_CASE(clipboard_authority_commit_rejects_stale_token_without_invoking_callback) {
    SessionClipboardAuthority owner;
    const auto old = owner.claim(7, 11, false, Alive);
    const auto next = owner.claim(8, 12, true, Alive);
    int calls = 0;
    const auto commit = [&] { ++calls; return true; };
    RDP_ASSERT(!owner.withAuthority(7, 11, old, Alive, commit));
    RDP_ASSERT(!owner.withAuthority(8, 11, next, Alive, commit));
    RDP_ASSERT(!owner.withAuthority(8, 12, 0, Alive, commit));
    RDP_ASSERT_EQ(calls, 0);
    RDP_ASSERT(owner.withAuthority(8, 12, next, Alive, commit));
    RDP_ASSERT_EQ(calls, 1);
}

RDP_TEST_CASE(clipboard_authority_commit_allows_nested_owns_but_blocks_reentrant_handoff) {
    SessionClipboardAuthority owner;
    const auto token = owner.claim(7, 11, false, Alive);
    bool nestedOwns = false;
    bool nestedCommit = false;
    bool revoked = true;
    uint64_t claimed = 99;
    RDP_ASSERT(owner.withAuthority(7, 11, token, Alive, [&] {
        nestedOwns = owner.owns(7, 11, token, Alive);
        claimed = owner.claim(8, 12, true, Alive);
        revoked = owner.revoke(7, 11, token, Alive);
        nestedCommit = owner.withAuthority(7, 11, token, Alive, [] { return true; });
        return true;
    }));
    RDP_ASSERT(nestedOwns && nestedCommit);
    RDP_ASSERT(!revoked);
    RDP_ASSERT_EQ(claimed, 0u);
    RDP_ASSERT(owner.revoke(7, 11, token, Alive));
}

RDP_TEST_CASE(clipboard_authority_commit_failure_and_exception_release_transaction_depth) {
    SessionClipboardAuthority owner;
    const auto token = owner.claim(7, 11, false, Alive);
    RDP_ASSERT(!owner.withAuthority(7, 11, token, Alive, [] { return false; }));
    RDP_ASSERT(!owner.withAuthority(7, 11, token, Alive, []() -> bool { throw std::runtime_error("commit failed"); }));
    RDP_ASSERT(owner.owns(7, 11, token, Alive));
    RDP_ASSERT(owner.claim(8, 12, true, Alive) > token);
}

RDP_TEST_CASE(clipboard_authority_commit_never_confirms_after_session_dies) {
    SessionClipboardAuthority owner;
    bool living = true;
    const auto alive = [&](int32_t, uint64_t) { return living; };
    const auto token = owner.claim(7, 11, false, alive);
    RDP_ASSERT(!owner.withAuthority(7, 11, token, alive, [&] { living = false; return true; }));
    RDP_ASSERT(!owner.owns(7, 11, token, Alive));
}

RDP_TEST_CASE(clipboard_authority_commit_serializes_cross_runtime_handoff_until_publication_finishes) {
    SessionClipboardAuthority owner;
    const auto token = owner.claim(7, 11, false, Alive);
    std::atomic<bool> attempted {false};
    std::atomic<bool> claimed {false};
    std::atomic<int> sequence {0};
    int publicationSequence = 0;
    int handoffSequence = 0;
    uint64_t next = 0;
    std::thread competitor;
    const bool accepted = owner.withAuthority(7, 11, token, Alive, [&] {
        competitor = std::thread([&] {
            attempted.store(true, std::memory_order_release);
            next = owner.claim(8, 12, true, Alive);
            handoffSequence = ++sequence;
            claimed.store(true, std::memory_order_release);
        });
        while (!attempted.load(std::memory_order_acquire)) { std::this_thread::yield(); }
        // A new runtime has entered claim; native ownership stays ours throughout
        // this synchronous publication, including a nested owns() query.
        if (claimed.load(std::memory_order_acquire) || !owner.owns(7, 11, token, Alive)) return false;
        publicationSequence = ++sequence;
        return true;
    });
    competitor.join();
    RDP_ASSERT(accepted);
    RDP_ASSERT_EQ(publicationSequence, 1);
    RDP_ASSERT_EQ(handoffSequence, 2);
    RDP_ASSERT(next > token);
    RDP_ASSERT(owner.owns(8, 12, next, Alive));
    RDP_ASSERT(!owner.withAuthority(7, 11, token, Alive, [] { return true; }));
}

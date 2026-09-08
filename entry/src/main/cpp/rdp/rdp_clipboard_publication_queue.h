#ifndef RDP_CLIPBOARD_PUBLICATION_QUEUE_H
#define RDP_CLIPBOARD_PUBLICATION_QUEUE_H

#include <chrono>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

// CB_FORMAT_LIST_RESPONSE has no request ID. Keep exactly one wire request
// outstanding, including failed/timed-out requests until their ACK drains.
class RdpClipboardPublicationQueue {
public:
    using Clock = std::chrono::steady_clock;
    struct Job {
        uint64_t id = 0;
        bool files = false;
        std::string text;
        std::vector<std::string> paths;
    };
    uint64_t enqueue(Job job, Clock::time_point now = Clock::now()) {
        std::lock_guard<std::mutex> lock(mutex_);
        invalidateLocked(); // A receipt authorizes only the latest desired value.
        job.id = ++nextId_;
        if (job.id == 0) job.id = ++nextId_;
        const auto id = job.id;
        records_[id] = {1, now};
        waiting_ = std::move(job);
        while (records_.size() > 128) records_.erase(records_.begin());
        return id;
    }
    std::optional<Job> takeNext(Clock::time_point now = Clock::now()) {
        std::lock_guard<std::mutex> lock(mutex_);
        expireLocked(now);
        if (inFlight_ || !waiting_) return {};
        auto result = std::move(waiting_);
        waiting_.reset();
        inFlight_ = result->id;
        return result;
    }
    void acknowledge(bool success, Clock::time_point now = Clock::now()) {
        std::lock_guard<std::mutex> lock(mutex_);
        expireLocked(now);
        auto record = records_.find(inFlight_);
        if (record != records_.end() && record->second.state == 1)
            record->second.state = success ? 2 : 3;
        inFlight_ = 0;
    }
    void sendFailed(uint64_t id, bool mayHaveBeenSent) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto record = records_.find(id);
        if (record != records_.end()) record->second.state = 3;
        if (inFlight_ == id && !mayHaveBeenSent) inFlight_ = 0;
    }
    int state(uint64_t id, Clock::time_point now = Clock::now()) {
        std::lock_guard<std::mutex> lock(mutex_);
        expireLocked(now);
        const auto record = records_.find(id);
        return record == records_.end() ? 0 : record->second.state;
    }
    void invalidate(bool newCarrier = false) {
        std::lock_guard<std::mutex> lock(mutex_);
        invalidateLocked();
        if (newCarrier) inFlight_ = 0;
    }
    bool hasWork() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return inFlight_ != 0 || waiting_.has_value();
    }
private:
    struct Record { int state; Clock::time_point created; };
    void invalidateLocked() {
        for (auto& entry : records_) entry.second.state = 3;
        waiting_.reset();
    }
    void expireLocked(Clock::time_point now) {
        for (auto& entry : records_) {
            if (entry.second.state == 1 && now - entry.second.created >= std::chrono::seconds(15))
                entry.second.state = 3;
        }
        if (waiting_ && records_[waiting_->id].state != 1) waiting_.reset();
    }
    mutable std::mutex mutex_;
    uint64_t nextId_ = 0;
    uint64_t inFlight_ = 0;
    std::optional<Job> waiting_;
    std::map<uint64_t, Record> records_;
};
#endif

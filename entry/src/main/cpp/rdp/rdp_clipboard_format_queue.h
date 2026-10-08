#ifndef RDP_CLIPBOARD_FORMAT_QUEUE_H
#define RDP_CLIPBOARD_FORMAT_QUEUE_H
#include "rdp_clipboard_content.h"
#include <chrono>
#include <map>
// Protected by adapter clipboardMutex; wire serialization belongs to
// RdpClipboardState, including cancelled/timed-out response draining.
class RdpClipboardFormatQueue {
public:
    using Clock = std::chrono::steady_clock;
    void offer(RdpClipboardFormatOffer offer) { invalidate(); offer_=std::move(offer); }
    const RdpClipboardFormatOffer& currentOffer() const { return offer_; }
    uint32_t formatId(uint64_t sequence,RdpClipboardFormat format) const {
        if (!sequence || sequence!=offer_.sequence) return 0;
        for (const auto& entry:offer_.formats) if (entry.format==format) return entry.formatId;
        return 0;
    }
    uint64_t request(uint64_t sequence,RdpClipboardFormat format,Clock::time_point now=Clock::now()) {
        if (!formatId(sequence,format)) return 0;
        // Limit retained payloads and queued work to one request per format.
        for (auto it=records_.begin();it!=records_.end();) {
            if (it->second.result.format==format) it=records_.erase(it); else ++it;
        }
        const auto id=++nextId_;
        Record record; record.created=now;
        record.result.requestId=id; record.result.sequence=sequence; record.result.format=format; record.result.state="loading";
        records_.emplace(id,std::move(record)); return id;
    }
    bool loading(uint64_t id,Clock::time_point now=Clock::now()) {
        expire(now); auto it=records_.find(id); return it!=records_.end()&&it->second.result.state=="loading";
    }
    void response(uint64_t id,bool success,const uint8_t* data,size_t size,Clock::time_point now=Clock::now()) {
        expire(now); auto it=records_.find(id); if (it==records_.end()) return;
        auto& result=it->second.result;
        if (result.state!="loading"||result.sequence!=offer_.sequence) return;
        if (!success||!RdpClipboardContentCodec::decode(result.format,data,size,result.content)) {
            result.state="failed"; result.diagnosticCode=success?"invalid_clipboard_payload":"remote_format_failed"; result.content={};
        } else result.state="ready";
    }
    void failed(uint64_t id) { auto it=records_.find(id); if (it!=records_.end()) { it->second.result.state="failed"; it->second.result.diagnosticCode="format_request_send_failed"; } }
    RdpClipboardFormatResult result(uint64_t id,Clock::time_point now=Clock::now()) { expire(now); auto it=records_.find(id); return it==records_.end()?RdpClipboardFormatResult{}:it->second.result; }
    bool release(uint64_t id) { return records_.erase(id)>0; }
    void invalidate() { offer_={}; for (auto& entry:records_) { entry.second.result.state="stale"; entry.second.result.content={}; entry.second.result.diagnosticCode="clipboard_offer_changed"; } }
private:
    struct Record { RdpClipboardFormatResult result; Clock::time_point created; };
    void expire(Clock::time_point now) { for (auto& entry:records_) if (entry.second.result.state=="loading"&&now-entry.second.created>=std::chrono::seconds(15)) { entry.second.result.state="timeout"; entry.second.result.diagnosticCode="format_response_timeout"; } }
    RdpClipboardFormatOffer offer_;
    uint64_t nextId_=0;
    std::map<uint64_t,Record> records_;
};
#endif

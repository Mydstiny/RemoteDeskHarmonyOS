#include "rdp/rdp_file_clipboard_offer.h"
#include "test_runner.h"

#include <string>
#include <vector>

RDP_TEST_CASE(rdp_file_clipboard_offer_builds_freerdp_uri_list) {
    RdpFileClipboardOffer offer;
    const auto result = offer.replace({
        "/data/storage/el2/base/files/rdp_transfer/alpha.txt",
        "/data/storage/el2/base/files/rdp_transfer/with space.txt"
    });

    RDP_ASSERT(result == RdpFileClipboardOfferResult::Ready);
    const auto snapshot = offer.snapshot();
    RDP_ASSERT(snapshot.ready());
    RDP_ASSERT_EQ(snapshot.paths.size(), 2U);
    RDP_ASSERT(snapshot.uriList ==
               std::string("file:///data/storage/el2/base/files/rdp_transfer/alpha.txt\r\n") +
               "file:///data/storage/el2/base/files/rdp_transfer/with space.txt\r\n");
}

RDP_TEST_CASE(rdp_file_clipboard_offer_rejects_unstable_or_unsafe_paths) {
    RdpFileClipboardOffer offer;

    RDP_ASSERT(offer.replace({}) == RdpFileClipboardOfferResult::Empty);
    RDP_ASSERT(offer.replace({"relative/file.txt"}) ==
               RdpFileClipboardOfferResult::InvalidPath);
    RDP_ASSERT(offer.replace({"/data/storage/file\nname.txt"}) ==
               RdpFileClipboardOfferResult::InvalidPath);
    RDP_ASSERT(!offer.snapshot().ready());
}

RDP_TEST_CASE(rdp_file_clipboard_offer_limits_one_batch_to_fifteen_files) {
    RdpFileClipboardOffer offer;
    std::vector<std::string> paths;
    for (size_t index = 0; index < RdpFileClipboardOffer::kMaxFilesPerOffer + 1; ++index) {
        paths.push_back("/data/storage/file-" + std::to_string(index));
    }

    RDP_ASSERT(offer.replace(paths) == RdpFileClipboardOfferResult::TooManyFiles);
    RDP_ASSERT(!offer.snapshot().ready());
}

RDP_TEST_CASE(rdp_file_clipboard_offer_generation_invalidates_stale_requests) {
    RdpFileClipboardOffer offer;
    RDP_ASSERT(offer.replace({"/data/storage/first.txt"}) ==
               RdpFileClipboardOfferResult::Ready);
    const uint64_t firstGeneration = offer.snapshot().generation;

    RDP_ASSERT(offer.replace({"/data/storage/second.txt"}) ==
               RdpFileClipboardOfferResult::Ready);
    const uint64_t secondGeneration = offer.snapshot().generation;
    RDP_ASSERT(secondGeneration > firstGeneration);
    RDP_ASSERT(!offer.isCurrent(firstGeneration));
    RDP_ASSERT(offer.isCurrent(secondGeneration));

    offer.clear();
    RDP_ASSERT(!offer.snapshot().ready());
    RDP_ASSERT(!offer.isCurrent(secondGeneration));
}

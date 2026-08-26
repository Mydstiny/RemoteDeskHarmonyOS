#include "moonlight/runtime/MoonlightHttpResponseFraming.h"
#include "test_runner.h"

#include <string>

namespace {

using namespace remotedesk::moonlight;

constexpr std::size_t HEADER_BUDGET = 4096U;
constexpr std::size_t BODY_BUDGET = 1024U;

MoonlightHttpFramingResult inspect(const std::string& wire,
                                   bool endOfStream = false,
                                   std::size_t bodyBudget = BODY_BUDGET) {
    return inspectMoonlightHttpResponse(
        wire, endOfStream, HEADER_BUDGET, bodyBudget);
}

} // namespace

RDP_TEST_CASE(moonlight_http_framing_waits_for_exact_content_length) {
    const std::string partial =
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhel";
    auto result = inspect(partial);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::NeedMore);
    RDP_ASSERT(result.headersComplete);
    RDP_ASSERT_EQ(result.httpStatus, 200);

    result = inspect(partial + "lo");
    RDP_ASSERT(result.complete());
    RDP_ASSERT(result.body == "hello");
}

RDP_TEST_CASE(moonlight_http_framing_accepts_identical_content_lengths) {
    const auto result = inspect(
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n"
        "Content-Length: 4, 4\r\n\r\ntest");
    RDP_ASSERT(result.complete());
    RDP_ASSERT(result.body == "test");
}

RDP_TEST_CASE(moonlight_http_framing_rejects_ambiguous_lengths) {
    auto result = inspect(
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\ntest");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);

    result = inspect(
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n"
        "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_rejects_extra_content_length_bytes) {
    const auto result = inspect(
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntestx");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_decodes_chunk_extensions_and_trailers) {
    const auto result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        "4;source=sunshine\r\nWiki\r\n5\r\npedia\r\n0\r\nReceipt: ok\r\n\r\n");
    RDP_ASSERT(result.complete());
    RDP_ASSERT(result.body == "Wikipedia");
}

RDP_TEST_CASE(moonlight_http_framing_waits_for_chunk_terminator) {
    const std::string partial =
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n";
    auto result = inspect(partial);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::NeedMore);
    RDP_ASSERT(result.headersComplete);

    result = inspect(partial, true);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_rejects_unsupported_transfer_codings) {
    auto result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);

    result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\npayload", true);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_rejects_malformed_chunks) {
    auto result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);

    result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_rejects_framing_fields_in_trailers) {
    const auto result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        "1\r\nx\r\n0\r\nContent-Length: 1\r\n\r\n");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_requires_eof_for_close_delimited_body) {
    const std::string wire = "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nhello";
    auto result = inspect(wire);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::NeedMore);
    RDP_ASSERT(result.headersComplete);

    result = inspect(wire, true);
    RDP_ASSERT(result.complete());
    RDP_ASSERT(result.body == "hello");
}

RDP_TEST_CASE(moonlight_http_framing_rejects_truncated_content_length) {
    const auto result = inspect(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel", true);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
    RDP_ASSERT(result.headersComplete);
}

RDP_TEST_CASE(moonlight_http_framing_enforces_decoded_body_budget) {
    auto result = inspect(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", false, 4U);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::BodyTooLarge);

    result = inspect(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        false, 4U);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::BodyTooLarge);

    result = inspect("HTTP/1.0 200 OK\r\n\r\nhello", true, 4U);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::BodyTooLarge);
}

RDP_TEST_CASE(moonlight_http_framing_rejects_malformed_status_and_headers) {
    auto result = inspect("HTTP/2 200 OK\r\nContent-Length: 0\r\n\r\n");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);

    result = inspect("HTTP/1.1 200 OK\r\n Folded: no\r\n\r\n", true);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);

    result = inspect("HTTP/1.1 200 OK\r\nMissing-Colon\r\n\r\n", true);
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

RDP_TEST_CASE(moonlight_http_framing_completes_no_body_status_at_headers) {
    auto result = inspect("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
    RDP_ASSERT(result.complete());
    RDP_ASSERT(result.body.empty());

    result = inspect("HTTP/1.1 304 Not Modified\r\n\r\nx");
    RDP_ASSERT_EQ(result.state, MoonlightHttpFramingState::ProtocolError);
}

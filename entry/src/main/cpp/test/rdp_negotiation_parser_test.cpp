/**
 * rdp_negotiation_parser_test.cpp - RDP TPKT/X.224 negotiation tests.
 */

#include "test_runner.h"
#include "rdp/rdp_negotiation_parser.h"

#include <vector>

namespace {

std::vector<uint8_t> responseFrame(uint32_t selectedProtocol) {
    return {
        0x03, 0x00, 0x00, 0x13,
        0x0e, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        static_cast<uint8_t>(selectedProtocol & 0xff),
        static_cast<uint8_t>((selectedProtocol >> 8) & 0xff),
        static_cast<uint8_t>((selectedProtocol >> 16) & 0xff),
        static_cast<uint8_t>((selectedProtocol >> 24) & 0xff),
    };
}

std::vector<uint8_t> failureFrame(uint32_t failureCode) {
    return {
        0x03, 0x00, 0x00, 0x13,
        0x0e, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x08, 0x00,
        static_cast<uint8_t>(failureCode & 0xff),
        static_cast<uint8_t>((failureCode >> 8) & 0xff),
        static_cast<uint8_t>((failureCode >> 16) & 0xff),
        static_cast<uint8_t>((failureCode >> 24) & 0xff),
    };
}

RdpNegotiation::ParseResult parseFragmented(const std::vector<uint8_t>& frame) {
    RdpNegotiation::RdpTpktAccumulator accumulator;
    for (const uint8_t byte : frame) {
        RDP_ASSERT(accumulator.append(&byte, 1));
    }
    return accumulator.parse();
}

} // namespace

RDP_TEST_CASE(rdp_negotiation_parser_accepts_tls_protocols) {
    const uint32_t protocols[] = {
        RdpNegotiation::kProtocolSsl,
        RdpNegotiation::kProtocolHybrid,
        RdpNegotiation::kProtocolRdsTls,
    };
    for (const uint32_t protocol : protocols) {
        const auto result = parseFragmented(responseFrame(protocol));
        RDP_ASSERT_EQ(static_cast<int>(result.status),
                      static_cast<int>(RdpNegotiation::ParseStatus::Complete));
        RDP_ASSERT_EQ(static_cast<int>(result.kind),
                      static_cast<int>(RdpNegotiation::ResponseKind::NegotiationResponse));
        RDP_ASSERT(result.selectedProtocol == protocol);
        RDP_ASSERT(RdpNegotiation::isTlsProtocol(result.selectedProtocol));
    }
}

RDP_TEST_CASE(rdp_negotiation_parser_handles_tpkt_and_pdu_fragmentation) {
    const auto frame = responseFrame(RdpNegotiation::kProtocolHybrid);
    for (size_t split = 0; split <= frame.size(); ++split) {
        RdpNegotiation::RdpTpktAccumulator accumulator;
        RDP_ASSERT(accumulator.append(frame.data(), split));
        RDP_ASSERT(accumulator.append(frame.data() + split, frame.size() - split));
        const auto result = accumulator.parse();
        RDP_ASSERT_EQ(static_cast<int>(result.status),
                      static_cast<int>(RdpNegotiation::ParseStatus::Complete));
        RDP_ASSERT(result.selectedProtocol == RdpNegotiation::kProtocolHybrid);
    }
}

RDP_TEST_CASE(rdp_negotiation_parser_reports_server_failure) {
    const auto result = parseFragmented(failureFrame(0x00000005));
    RDP_ASSERT_EQ(static_cast<int>(result.status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Complete));
    RDP_ASSERT_EQ(static_cast<int>(result.kind),
                  static_cast<int>(RdpNegotiation::ResponseKind::NegotiationFailure));
    RDP_ASSERT(result.failureCode == 0x00000005);
    RDP_ASSERT(std::string(RdpNegotiation::failureCodeName(result.failureCode)) ==
               "HYBRID_REQUIRED_BY_SERVER");
}

RDP_TEST_CASE(rdp_negotiation_parser_classifies_standard_security) {
    const std::vector<uint8_t> frame = {
        0x03, 0x00, 0x00, 0x0b,
        0x06, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const auto result = parseFragmented(frame);
    RDP_ASSERT_EQ(static_cast<int>(result.status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Complete));
    RDP_ASSERT_EQ(static_cast<int>(result.kind),
                  static_cast<int>(RdpNegotiation::ResponseKind::NoNegotiationData));

    const auto explicitRdpSelection = parseFragmented(
        responseFrame(RdpNegotiation::kProtocolRdp));
    RDP_ASSERT_EQ(static_cast<int>(explicitRdpSelection.status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Complete));
    RDP_ASSERT_EQ(static_cast<int>(explicitRdpSelection.kind),
                  static_cast<int>(RdpNegotiation::ResponseKind::NegotiationResponse));
    RDP_ASSERT(!RdpNegotiation::isTlsProtocol(explicitRdpSelection.selectedProtocol));
}

RDP_TEST_CASE(rdp_negotiation_parser_rejects_invalid_and_unknown_pdus) {
    auto badVersion = responseFrame(RdpNegotiation::kProtocolSsl);
    badVersion[0] = 0x02;
    RDP_ASSERT_EQ(static_cast<int>(RdpNegotiation::parseRdpNegotiationResponse(badVersion).status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Invalid));

    auto badLength = responseFrame(RdpNegotiation::kProtocolSsl);
    badLength[2] = 0x00;
    badLength[3] = 0x06;
    RDP_ASSERT_EQ(static_cast<int>(RdpNegotiation::parseRdpNegotiationResponse(badLength).status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Invalid));

    auto unknownPdu = responseFrame(RdpNegotiation::kProtocolSsl);
    unknownPdu[11] = 0x06;
    const auto unknownResult = RdpNegotiation::parseRdpNegotiationResponse(unknownPdu);
    RDP_ASSERT_EQ(static_cast<int>(unknownResult.status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Invalid));

    auto badFailureFlags = failureFrame(0x00000001);
    badFailureFlags[12] = 0x01;
    RDP_ASSERT_EQ(static_cast<int>(RdpNegotiation::parseRdpNegotiationResponse(badFailureFlags).status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Invalid));

    auto badNegotiationLength = responseFrame(RdpNegotiation::kProtocolSsl);
    badNegotiationLength[13] = 0x07;
    RDP_ASSERT_EQ(static_cast<int>(RdpNegotiation::parseRdpNegotiationResponse(badNegotiationLength).status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Invalid));

    auto trailingBytes = responseFrame(RdpNegotiation::kProtocolSsl);
    trailingBytes.push_back(0x00);
    RDP_ASSERT_EQ(static_cast<int>(RdpNegotiation::parseRdpNegotiationResponse(trailingBytes).status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Invalid));

    const std::vector<uint8_t> incompleteHeader = {0x03, 0x00, 0x00};
    RDP_ASSERT_EQ(static_cast<int>(RdpNegotiation::parseRdpNegotiationResponse(incompleteHeader).status),
                  static_cast<int>(RdpNegotiation::ParseStatus::NeedMoreData));
}

RDP_TEST_CASE(rdp_negotiation_parser_keeps_unknown_protocol_non_tls) {
    const auto result = parseFragmented(responseFrame(0x00000020));
    RDP_ASSERT_EQ(static_cast<int>(result.status),
                  static_cast<int>(RdpNegotiation::ParseStatus::Complete));
    RDP_ASSERT(!RdpNegotiation::isTlsProtocol(result.selectedProtocol));
    RDP_ASSERT(std::string(RdpNegotiation::selectedProtocolName(result.selectedProtocol)) ==
               "UNKNOWN");
}

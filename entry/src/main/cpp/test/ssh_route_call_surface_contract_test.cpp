#include "test_runner.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>
#include <unordered_set>
#include <vector>

#ifndef REMOTEDESK_NATIVE_SOURCE_DIR
#error "REMOTEDESK_NATIVE_SOURCE_DIR is required for production call-surface tests"
#endif

namespace {

std::string readProductionAdapter() {
    const std::string path =
        std::string(REMOTEDESK_NATIVE_SOURCE_DIR) + "/ssh/ssh_adapter.cpp";
    std::ifstream input(path, std::ios::binary);
    return std::string(
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>());
}

std::string stripCommentsAndLiterals(const std::string& source) {
    enum class State { Code, LineComment, BlockComment, String, Character };
    State state = State::Code;
    std::string code(source.size(), ' ');
    for (std::size_t index = 0; index < source.size(); ++index) {
        const char current = source[index];
        const char next = index + 1 < source.size() ? source[index + 1] : '\0';
        if (current == '\n') { code[index] = '\n'; }
        switch (state) {
            case State::Code:
                if (current == '/' && next == '/') {
                    state = State::LineComment;
                    ++index;
                } else if (current == '/' && next == '*') {
                    state = State::BlockComment;
                    ++index;
                } else if (current == '"') {
                    state = State::String;
                } else if (current == '\'') {
                    state = State::Character;
                } else {
                    code[index] = current;
                }
                break;
            case State::LineComment:
                if (current == '\n') { state = State::Code; }
                break;
            case State::BlockComment:
                if (current == '*' && next == '/') {
                    ++index;
                    state = State::Code;
                }
                break;
            case State::String:
            case State::Character: {
                const State quotedState = state;
                if (current == '\\' && index + 1 < source.size()) {
                    ++index;
                } else if ((quotedState == State::String && current == '"') ||
                           (quotedState == State::Character && current == '\'')) {
                    state = State::Code;
                }
                break;
            }
        }
    }
    return code;
}

std::vector<std::size_t> callPositions(
    const std::string& code, const std::string& token) {
    std::vector<std::size_t> positions;
    std::size_t position = 0;
    while ((position = code.find(token, position)) != std::string::npos) {
        positions.push_back(position);
        position += token.size();
    }
    return positions;
}

std::string enclosingAdapterMethod(
    const std::string& code, std::size_t position) {
    constexpr const char* kMarker = "SshAdapter::";
    std::size_t searchFrom = position;
    while (true) {
        const std::size_t marker = code.rfind(kMarker, searchFrom);
        if (marker == std::string::npos) { return {}; }
        const std::size_t nameStart =
            marker + std::char_traits<char>::length(kMarker);
        std::size_t nameEnd = nameStart;
        while (nameEnd < code.size() &&
               ((code[nameEnd] >= 'a' && code[nameEnd] <= 'z') ||
                (code[nameEnd] >= 'A' && code[nameEnd] <= 'Z') ||
                (code[nameEnd] >= '0' && code[nameEnd] <= '9') ||
                code[nameEnd] == '_')) {
            ++nameEnd;
        }
        std::size_t openParen = nameEnd;
        while (openParen < code.size() &&
               (code[openParen] == ' ' || code[openParen] == '\t' ||
                code[openParen] == '\n' || code[openParen] == '\r')) {
            ++openParen;
        }
        if (nameEnd > nameStart && openParen < position &&
            code[openParen] == '(') {
            return code.substr(nameStart, nameEnd - nameStart);
        }
        if (marker == 0) { return {}; }
        searchFrom = marker - 1;
    }
}

bool nearbyBefore(
    const std::string& code, std::size_t position, std::size_t window,
    const std::vector<std::string>& markers) {
    const std::size_t begin = position > window ? position - window : 0;
    const std::string context = code.substr(begin, position - begin);
    return std::any_of(markers.begin(), markers.end(), [&](const std::string& marker) {
        return context.find(marker) != std::string::npos;
    });
}

bool nearbyAfter(
    const std::string& code, std::size_t position, std::size_t window,
    const std::string& marker) {
    return code.substr(position, std::min(window, code.size() - position))
        .find(marker) != std::string::npos;
}

bool everyCallIsIn(
    const std::string& code, const std::vector<std::size_t>& positions,
    const std::unordered_set<std::string>& methods) {
    return std::all_of(positions.begin(), positions.end(), [&](std::size_t position) {
        return methods.find(enclosingAdapterMethod(code, position)) != methods.end();
    });
}

} // namespace

RDP_TEST_CASE(ssh_production_call_surface_fences_handshake_and_kbi) {
    const std::string code = stripCommentsAndLiterals(readProductionAdapter());
    RDP_ASSERT(!code.empty());

    const auto handshakes = callPositions(code, "libssh2_session_handshake(");
    RDP_ASSERT(handshakes.size() == 2);
    RDP_ASSERT(everyCallIsIn(
        code, handshakes, {"connectThroughSshJump", "sshHandshake"}));
    RDP_ASSERT(std::all_of(handshakes.begin(), handshakes.end(), [&](std::size_t position) {
        return nearbyBefore(code, position, 700, {"admitRouteWrite("});
    }));

    const auto interactive = callPositions(
        code, "libssh2_userauth_keyboard_interactive(");
    RDP_ASSERT(interactive.size() == 2);
    RDP_ASSERT(everyCallIsIn(
        code, interactive,
        {"connectThroughSshJump", "authenticateKeyboardInteractive"}));
    RDP_ASSERT(std::all_of(
        interactive.begin(), interactive.end(), [&](std::size_t position) {
            return nearbyBefore(
                       code, position, 900,
                       {"beginKeyboardInteractiveCallAdmission("}) &&
                nearbyAfter(
                       code, position, 500, "authRouteAdmission_.endCall(");
        }));
}

RDP_TEST_CASE(ssh_production_call_surface_fences_window_adjust_reads) {
    const std::string code = stripCommentsAndLiterals(readProductionAdapter());
    std::vector<std::size_t> reads =
        callPositions(code, "libssh2_channel_read(");
    const auto stderrReads =
        callPositions(code, "libssh2_channel_read_stderr(");
    reads.insert(reads.end(), stderrReads.begin(), stderrReads.end());
    RDP_ASSERT(reads.size() == 7);
    RDP_ASSERT(std::all_of(reads.begin(), reads.end(), [&](std::size_t position) {
        return nearbyBefore(
            code, position, 700,
            {"admitConnectedRouteRead(", "admitRouteWrite("});
    }));

    std::vector<std::size_t> sftpReads =
        callPositions(code, "libssh2_sftp_read(");
    const auto directoryReads =
        callPositions(code, "libssh2_sftp_readdir_ex(");
    sftpReads.insert(sftpReads.end(), directoryReads.begin(), directoryReads.end());
    RDP_ASSERT(sftpReads.size() == 3);
    RDP_ASSERT(std::all_of(
        sftpReads.begin(), sftpReads.end(), [&](std::size_t position) {
            return nearbyBefore(
                code, position, 500, {"admitConnectedRouteWrite("});
        }));
}

RDP_TEST_CASE(ssh_production_call_surface_routes_teardown_through_retirement) {
    const std::string code = stripCommentsAndLiterals(readProductionAdapter());

    const auto disconnects =
        callPositions(code, "libssh2_session_disconnect(");
    RDP_ASSERT(disconnects.size() == 1);
    RDP_ASSERT(everyCallIsIn(code, disconnects, {"teardownSessionHandlesLocked"}));
    RDP_ASSERT(nearbyBefore(
        code, disconnects.front(), 500,
        {"runTransportTeardownPrimitiveLocked("}));

    const auto sessionFrees = callPositions(code, "libssh2_session_free(");
    RDP_ASSERT(sessionFrees.size() == 2);
    RDP_ASSERT(everyCallIsIn(
        code, sessionFrees,
        {"teardownSessionHandlesLocked", "stopSshJumpRelay"}));
    RDP_ASSERT(std::all_of(
        sessionFrees.begin(), sessionFrees.end(), [&](std::size_t position) {
            return nearbyBefore(
                code, position, 1600,
                {"runTransportTeardownPrimitiveLocked(", "shutdown("});
        }));

    const auto channelFrees = callPositions(code, "libssh2_channel_free(");
    RDP_ASSERT(channelFrees.size() == 7);
    RDP_ASSERT(std::all_of(
        channelFrees.begin(), channelFrees.end(), [&](std::size_t position) {
            return nearbyBefore(
                code, position, 1600,
                {"admitConnectedRouteWrite(",
                 "runTransportTeardownPrimitiveLocked(",
                 "admitRouteWrite(", "shutdown("});
        }));

    const std::size_t handshakeStart = code.find("int SshAdapter::sshHandshake(");
    const std::size_t handshakeEnd = code.find(
        "int SshAdapter::authenticatePassword(", handshakeStart);
    RDP_ASSERT(handshakeStart != std::string::npos);
    RDP_ASSERT(handshakeEnd != std::string::npos);
    RDP_ASSERT(code.substr(handshakeStart, handshakeEnd - handshakeStart)
        .find("libssh2_session_free(") == std::string::npos);
}

RDP_TEST_CASE(ssh_production_call_surface_owns_kbi_secret_release) {
    const std::string code = stripCommentsAndLiterals(readProductionAdapter());
    RDP_ASSERT(callPositions(code, "libssh2_session_init(").empty());
    const auto extendedInit = callPositions(code, "libssh2_session_init_ex(");
    RDP_ASSERT(extendedInit.size() == 1);
    RDP_ASSERT(nearbyBefore(
        code, extendedInit.front(), 200,
        {"createSshSession("}));
    RDP_ASSERT(nearbyAfter(
        code, extendedInit.front(), 250, "sshLibssh2Free"));
    RDP_ASSERT(callPositions(code, "sshAllocateTrackedSensitive(").size() == 1);
    RDP_ASSERT(callPositions(
        code, "SshSensitiveStringCollectionGuard<").size() == 1);
}

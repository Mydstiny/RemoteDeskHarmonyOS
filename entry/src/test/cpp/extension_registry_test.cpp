/**
 * extension_registry_test.cpp — 扩展注册中心单元测试
 */

#include "extensions/extension_registry.h"
#include "extensions/protocol_adapter.h"
#include "test/test_runner.h"
#include <iostream>
#include <memory>

// 模拟协议适配器用于测试
class MockAdapter : public ProtocolAdapter {
    std::string name_;
public:
    explicit MockAdapter(const std::string& name) : name_(name) {}
    std::string protocolName() override { return name_; }
    int defaultPort() override { return 9999; }
    int connect(const ConnectionConfig&) override { return 0; }
    void disconnect() override {}
    ConnectionState getState() override { return ConnectionState::DISCONNECTED; }
    void sendKey(uint32_t, bool) override {}
    void sendMouse(int, int, MouseButton, bool) override {}
    void sendMouseWheel(int, int, int) override {}
    void sendText(const std::string&) override {}
    bool supportsCodec(CodecType) override { return true; }
    std::vector<CodecType> supportedCodecs() override { return {CodecType::H264}; }
    void setVideoCallback(VideoFrameCallback) override {}
    void setAudioCallback(AudioDataCallback) override {}
    void setConnectionStateCallback(ConnectionStateCallback) override {}
};

void test_register_and_get() {
    ExtensionRegistry<ProtocolAdapter> registry;
    auto adapter1 = std::make_shared<MockAdapter>("RDP");
    auto adapter2 = std::make_shared<MockAdapter>("RustDesk");

    registry.registerExt("protocol", "rdp", adapter1);
    registry.registerExt("protocol", "rustdesk", adapter2);

    auto result = registry.get("protocol");
    RDP_ASSERT(result.size() == 2);
    std::cout << "✓ test_register_and_get 通过" << std::endl;
}

void test_get_by_name() {
    ExtensionRegistry<ProtocolAdapter> registry;
    registry.registerExt("protocol", "rdp", std::make_shared<MockAdapter>("RDP"));
    registry.registerExt("protocol", "rustdesk", std::make_shared<MockAdapter>("RustDesk"));

    auto rdp = registry.getByName("protocol", "rdp");
    RDP_ASSERT(rdp != nullptr);
    RDP_ASSERT(rdp->protocolName() == "RDP");

    auto missing = registry.getByName("protocol", "vnc");
    RDP_ASSERT(missing == nullptr);
    std::cout << "✓ test_get_by_name 通过" << std::endl;
}

void test_list_names() {
    ExtensionRegistry<ProtocolAdapter> registry;
    registry.registerExt("protocol", "rdp", std::make_shared<MockAdapter>("RDP"));

    auto names = registry.listNames("protocol");
    RDP_ASSERT(names.size() == 1);
    RDP_ASSERT(names[0] == "rdp");
    std::cout << "✓ test_list_names 通过" << std::endl;
}

void test_unregister() {
    ExtensionRegistry<ProtocolAdapter> registry;
    registry.registerExt("protocol", "rdp", std::make_shared<MockAdapter>("RDP"));
    RDP_ASSERT(registry.size() == 1);

    bool removed = registry.unregister("protocol", "rdp");
    RDP_ASSERT(removed);
    RDP_ASSERT(registry.size() == 0);
    std::cout << "✓ test_unregister 通过" << std::endl;
}

void test_extension_system_singleton() {
    auto& sys1 = ExtensionSystem::instance();
    auto& sys2 = ExtensionSystem::instance();
    RDP_ASSERT(&sys1 == &sys2);
    std::cout << "✓ test_extension_system_singleton 通过" << std::endl;
}

void runExtensionRegistryTests() {
    std::cout << "=== Extension Registry 单元测试 ===" << std::endl;
    test_register_and_get();
    test_get_by_name();
    test_list_names();
    test_unregister();
    test_extension_system_singleton();
}

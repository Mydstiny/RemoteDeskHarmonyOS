/**
 * test_runner.h — 轻量原生单元测试框架
 *
 * 用法:
 *   RDP_TEST_CASE(frame_stats_basic) {
 *       Perf::FrameStats stats;
 *       stats.recordFrame(0);
 *       stats.recordFrame(16666); // ~60fps interval
 *       RDP_ASSERT(stats.frameCount.load() == 2);
 *   }
 *
 * 编译: cmake -DRDP_BUILD_TESTS=ON
 * 运行: 独立 test binary → hdc shell /data/local/tmp/rdp_test
 */

#ifndef TEST_RUNNER_H
#define TEST_RUNNER_H

#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <functional>

// ---- 测试注册 ----
struct TestCase {
    const char* name;
    std::function<void()> func;
};

inline std::vector<TestCase>& testRegistry() {
    static std::vector<TestCase> registry;
    return registry;
}

#define RDP_TEST_CASE(name) \
    static void rdp_test_##name(); \
    static struct RdpTestReg_##name { \
        RdpTestReg_##name() { \
            testRegistry().push_back({#name, rdp_test_##name}); \
        } \
    } rdp_test_reg_##name; \
    static void rdp_test_##name()

// ---- 断言 ----
#define RDP_ASSERT(cond) \
    do { if (!(cond)) { \
        std::fprintf(stderr, "  FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        std::abort(); \
    } } while(0)

#define RDP_ASSERT_EQ(a, b) \
    do { if ((a) != (b)) { \
        std::fprintf(stderr, "  FAIL: %s:%d: %s == %s (%lld != %lld)\n", \
            __FILE__, __LINE__, #a, #b, (long long)(a), (long long)(b)); \
        std::abort(); \
    } } while(0)

// ---- 运行器 ----
inline int runAllTests() {
    auto& registry = testRegistry();
    int passed = 0, failed = 0;
    std::printf("Running %zu tests...\n", registry.size());
    for (auto& tc : registry) {
        std::printf("  %s ... ", tc.name);
        try {
            tc.func();
            std::printf("OK\n");
            passed++;
        } catch (...) {
            std::printf("FAIL (exception)\n");
            failed++;
        }
    }
    std::printf("\n%d passed, %d failed, %zu total\n", passed, failed, registry.size());
    return failed;
}

#endif // TEST_RUNNER_H

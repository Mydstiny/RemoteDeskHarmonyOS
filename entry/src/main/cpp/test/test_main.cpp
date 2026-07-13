/**
 * test_main.cpp — 原生单元测试入口
 *
 * 编译: cmake -DRDP_BUILD_TESTS=ON
 * 运行: hdc shell /data/local/tmp/rdp_test
 */
#include "test_runner.h"

void runExtensionRegistryTests();

int main() {
    runExtensionRegistryTests();
    return runAllTests();
}

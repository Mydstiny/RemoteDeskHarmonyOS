# CMakeLists.txt — 原生 C++ 测试构建配置

cmake_minimum_required(VERSION 3.5.0)
project(rdp_tests)

set(CMAKE_CXX_STANDARD 17)

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/../../main/cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../main/cpp/extensions
    ${CMAKE_CURRENT_SOURCE_DIR}/../../main/cpp/security
)

# 扩展注册中心测试
add_executable(extension_registry_test extension_registry_test.cpp)
target_link_libraries(extension_registry_test libhilog_ndk.z.so)

# 主机锁测试
add_executable(host_locker_test
    host_locker_test.cpp
    ../../main/cpp/security/host_locker.cpp
    ../../main/cpp/security/crypto_utils.cpp
)
target_link_libraries(host_locker_test libhilog_ndk.z.so)

/**
 * host_locker_test.cpp — 主机安全锁单元测试
 */

#include "security/host_locker.h"
#include "extensions/data_provider.h"
#include <cassert>
#include <iostream>

void test_set_and_verify_lock() {
    HostLocker& locker = HostLocker::instance();
    locker.initialize();

    const std::string hostId = "test_host_001";
    const std::string credential = "test_password_123";

    // 设置锁
    bool setResult = locker.setLock(hostId, LockType::PASSWORD, credential);
    assert(setResult);

    // 正确凭证验证
    bool verifyOk = locker.verifyLock(hostId, credential);
    assert(verifyOk);

    // 错误凭证验证
    bool verifyBad = locker.verifyLock(hostId, "wrong_password");
    assert(!verifyBad);

    std::cout << "✓ test_set_and_verify_lock 通过" << std::endl;
}

void test_remove_lock() {
    HostLocker& locker = HostLocker::instance();
    locker.initialize();

    const std::string hostId = "test_host_002";
    locker.setLock(hostId, LockType::PIN, "123456");

    bool removed = locker.removeLock(hostId);
    assert(removed);
    assert(!locker.isLocked(hostId));

    std::cout << "✓ test_remove_lock 通过" << std::endl;
}

void test_is_locked() {
    HostLocker& locker = HostLocker::instance();
    locker.initialize();

    const std::string hostId = "test_host_003";
    assert(!locker.isLocked(hostId));

    locker.setLock(hostId, LockType::BIOMETRIC, "");
    assert(locker.isLocked(hostId));

    locker.removeLock(hostId);
    assert(!locker.isLocked(hostId));

    std::cout << "✓ test_is_locked 通过" << std::endl;
}

void test_lock_type() {
    HostLocker& locker = HostLocker::instance();
    locker.initialize();

    const std::string hostId = "test_host_004";
    locker.setLock(hostId, LockType::BIOMETRIC, "");

    LockType type = locker.getLockType(hostId);
    assert(type == LockType::BIOMETRIC);

    locker.removeLock(hostId);
    assert(locker.getLockType(hostId) == LockType::NONE);

    std::cout << "✓ test_lock_type 通过" << std::endl;
}

int main() {
    std::cout << "=== HostLocker 单元测试 ===" << std::endl;
    test_set_and_verify_lock();
    test_remove_lock();
    test_is_locked();
    test_lock_type();
    std::cout << "全部测试通过!" << std::endl;
    return 0;
}

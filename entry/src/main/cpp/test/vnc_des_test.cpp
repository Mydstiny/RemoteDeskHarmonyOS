/** VNC password-auth DES test vectors. */
#include "test_runner.h"
#include "vnc/vnc_des.h"

RDP_TEST_CASE(vnc_des_matches_fips_vector) {
    const uint8_t key[8] = {0x13, 0x34, 0x57, 0x79, 0x9B, 0xBC, 0xDF, 0xF1};
    const uint8_t input[8] = {0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF};
    const uint8_t expected[8] = {0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05};
    uint8_t output[8] = {0};
    vncDesEncryptBlock(key, input, output);
    for (size_t index = 0; index < sizeof(output); ++index) RDP_ASSERT(output[index] == expected[index]);
}

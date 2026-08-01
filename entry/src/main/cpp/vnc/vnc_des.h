/**
 * vnc_des.h - the DES-ECB primitive required by legacy VNC password auth.
 *
 * VNC reverses the bits in each password byte and encrypts the 16-byte
 * challenge as two DES ECB blocks. This small protocol primitive is kept
 * independent from the project's OpenSSL build, which intentionally disables
 * the deprecated DES provider.
 */
#ifndef VNC_DES_H
#define VNC_DES_H

#include <cstdint>

void vncDesEncryptBlock(const uint8_t key[8], const uint8_t input[8], uint8_t output[8]);

#endif // VNC_DES_H

#ifndef RUSTDESK_PHONE_SCOPE_H
#define RUSTDESK_PHONE_SCOPE_H
#include <cstdint>

inline bool RustDeskPhoneRequestAllowed(bool selected, uint64_t generation, uint64_t owner,
    uint64_t epoch, uint64_t requestGeneration, uint64_t requestOwner,
    uint64_t requestEpoch, int operation) {
    return selected && generation != 0 && owner != 0 && epoch != 0 &&
        requestGeneration == generation && requestOwner == owner && operation >= -2 && operation <= 13 &&
        (operation == -2 || (requestEpoch != 0 && requestEpoch == epoch));
}
#endif

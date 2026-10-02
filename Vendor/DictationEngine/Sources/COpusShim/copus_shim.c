#include "copus_shim.h"
#include <string.h>

int typeless_opus_encoder_ctl_int(OpusEncoder *st, int request, int value) {
    return opus_encoder_ctl(st, request, value);
}

int typeless_opus_encoder_get_int(OpusEncoder *st, int request, int *value) {
    return opus_encoder_ctl(st, request, value);
}

void typeless_ws_xor(uint8_t *buf, size_t len, const uint8_t key[4], size_t offset) {
    /* Rotate the key so that buf[0] pairs with key[offset % 4]. */
    uint8_t k[8];
    for (int i = 0; i < 8; i++) k[i] = key[(offset + (size_t)i) & 3];
    uint64_t k64;
    memcpy(&k64, k, 8);
    size_t i = 0;
    for (; i + 8 <= len; i += 8) {
        uint64_t w;
        memcpy(&w, buf + i, 8);
        w ^= k64;
        memcpy(buf + i, &w, 8);
    }
    for (; i < len; i++) buf[i] ^= k[i & 7];
}

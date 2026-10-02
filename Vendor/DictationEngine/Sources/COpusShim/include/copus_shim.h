#ifndef TYPELESS_COPUS_SHIM_C_H
#define TYPELESS_COPUS_SHIM_C_H

#include <stddef.h>
#include <stdint.h>
#include <opus.h>

#ifdef __cplusplus
extern "C" {
#endif

/* opus_encoder_ctl is variadic and therefore not callable from Swift. */
int typeless_opus_encoder_ctl_int(OpusEncoder *st, int request, int value);
int typeless_opus_encoder_get_int(OpusEncoder *st, int request, int *value);

/* RFC 6455 XOR (un)masking, 8 bytes per iteration. `key` is the 4-byte mask, `offset`
 * is the payload offset at which `buf` starts (so fragments keep the key phase). */
void typeless_ws_xor(uint8_t *buf, size_t len, const uint8_t key[4], size_t offset);

#ifdef __cplusplus
}
#endif
#endif

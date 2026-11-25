#ifndef CNETSTAT_H
#define CNETSTAT_H

#include <stdint.h>

/// Totals across this Mac's TCP connections that carry traffic over a real
/// network interface (Wi-Fi, Ethernet, cellular), for the interval since the
/// previous sample. Loopback traffic is excluded.
typedef struct {
    uint64_t tx_packets;
    uint64_t rx_bytes;
    uint64_t resent_bytes;
    uint32_t resending_connections;   // resent at least one packet this interval
} cn_sample;

typedef struct cn_ctx cn_ctx;

/// Opens the kernel network-statistics interface. Returns NULL and sets
/// *err to an errno when the kernel refuses.
cn_ctx *cn_open(int *err);
void cn_close(cn_ctx *ctx);

/// Fills *out with totals since the previous call. Returns 0 or an errno.
/// The first call after cn_open establishes the starting point and reports zeros.
int cn_sample_now(cn_ctx *ctx, cn_sample *out);

#endif

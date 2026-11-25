// Reads per-connection TCP statistics from the kernel's network-statistics
// control socket (xnu bsd/net/ntstat.c). The interface is private to Apple but
// its message layout has been stable since macOS 10.13 (__NSTAT_REVISION__ 9);
// the vendored headers in xnu/ are the published xnu sources.

#include "cnetstat.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <netinet/if_ether.h>

#define PRIVATE 1
#include <net/ntstat.h>

typedef struct {
    uint64_t ref;          // 0 marks an empty slot
    uint64_t tx_packets;
    uint64_t rx_bytes;
    uint64_t resent_bytes;
    uint64_t net_bytes;    // cell + wifi + wired, both directions
    uint8_t  has_prev;
    uint8_t  tombstone;
} entry;

struct cn_ctx {
    int fd;
    uint64_t next_context;
    entry *slots;
    size_t capacity;       // power of two
    size_t used;           // live + tombstones
    int primed;            // first sample taken
    // Accumulators for the sample in progress.
    cn_sample acc;
};

// MARK: - Source table (open addressing keyed by kernel source ref)

static size_t slot_index(uint64_t ref, size_t cap) {
    uint64_t h = ref * 0x9E3779B97F4A7C15ull;
    return (size_t)(h >> 32) & (cap - 1);
}

static entry *table_find(cn_ctx *c, uint64_t ref) {
    size_t i = slot_index(ref, c->capacity);
    for (size_t n = 0; n < c->capacity; n++, i = (i + 1) & (c->capacity - 1)) {
        entry *e = &c->slots[i];
        if (e->ref == ref && !e->tombstone) return e;
        if (e->ref == 0 && !e->tombstone) return NULL;
    }
    return NULL;
}

static int table_grow(cn_ctx *c);

static entry *table_insert(cn_ctx *c, uint64_t ref) {
    entry *found = table_find(c, ref);
    if (found) return found;
    if ((c->used + 1) * 2 > c->capacity && table_grow(c) != 0) return NULL;
    size_t i = slot_index(ref, c->capacity);
    for (;; i = (i + 1) & (c->capacity - 1)) {
        entry *e = &c->slots[i];
        if (e->ref == 0 || e->tombstone) {
            if (e->ref == 0) c->used++;
            memset(e, 0, sizeof(*e));
            e->ref = ref;
            return e;
        }
    }
}

static int table_grow(cn_ctx *c) {
    size_t old_cap = c->capacity;
    entry *old = c->slots;
    // Size from live entries so tombstones left by closed connections don't
    // ratchet the table up over days of running.
    size_t live = 0;
    for (size_t i = 0; i < old_cap; i++) {
        if (old[i].ref != 0 && !old[i].tombstone) live++;
    }
    size_t new_cap = 256;
    while (new_cap < (live + 1) * 4) new_cap *= 2;
    entry *fresh = calloc(new_cap, sizeof(entry));
    if (!fresh) return ENOMEM;
    c->slots = fresh;
    c->capacity = new_cap;
    c->used = 0;
    for (size_t i = 0; i < old_cap; i++) {
        if (old[i].ref != 0 && !old[i].tombstone) {
            entry *e = table_insert(c, old[i].ref);
            *e = old[i];
        }
    }
    free(old);
    return 0;
}

static void table_remove(cn_ctx *c, uint64_t ref) {
    entry *e = table_find(c, ref);
    if (e) e->tombstone = 1;
}

// MARK: - Message handling

static void handle_counts(cn_ctx *c, const nstat_msg_src_counts *m) {
    const nstat_counts *k = &m->counts;
    uint64_t net = k->nstat_cell_rxbytes + k->nstat_cell_txbytes
                 + k->nstat_wifi_rxbytes + k->nstat_wifi_txbytes
                 + k->nstat_wired_rxbytes + k->nstat_wired_txbytes;
    entry *e = table_insert(c, m->srcref);
    if (!e) return;
    if (e->has_prev && net > e->net_bytes) {
        uint64_t tx = k->nstat_txpackets >= e->tx_packets ? k->nstat_txpackets - e->tx_packets : 0;
        uint64_t rx = k->nstat_rxbytes >= e->rx_bytes ? k->nstat_rxbytes - e->rx_bytes : 0;
        uint64_t re = k->nstat_txretransmit >= e->resent_bytes ? k->nstat_txretransmit - e->resent_bytes : 0;
        c->acc.tx_packets += tx;
        c->acc.rx_bytes += rx;
        c->acc.resent_bytes += re;
        if (re > 0) c->acc.resending_connections++;
    }
    e->tx_packets = k->nstat_txpackets;
    e->rx_bytes = k->nstat_rxbytes;
    e->resent_bytes = k->nstat_txretransmit;
    e->net_bytes = net;
    // Connections first seen after the initial snapshot started from zero,
    // so their whole history belongs to the current interval.
    e->has_prev = 1;
}

/// Processes every message in buf. Returns 1 when the reply to `context`
/// ended the query, sets *more when the kernel asked for another fragment.
static int handle_buffer(cn_ctx *c, const uint8_t *buf, size_t n, uint64_t context, int *more, int *err) {
    int done = 0;
    size_t off = 0;
    while (off + sizeof(nstat_msg_hdr) <= n) {
        nstat_msg_hdr hdr;
        memcpy(&hdr, buf + off, sizeof(hdr));
        if (hdr.length < sizeof(nstat_msg_hdr) || off + hdr.length > n) break;
        switch (hdr.type) {
        case NSTAT_MSG_TYPE_SRC_ADDED: {
            nstat_msg_src_added m;
            if (hdr.length >= sizeof(m)) {
                memcpy(&m, buf + off, sizeof(m));
                entry *e = table_insert(c, m.srcref);
                if (e && c->primed) e->has_prev = 1;
            }
            break;
        }
        case NSTAT_MSG_TYPE_SRC_REMOVED: {
            nstat_msg_src_removed m;
            if (hdr.length >= sizeof(m)) {
                memcpy(&m, buf + off, sizeof(m));
                table_remove(c, m.srcref);
            }
            break;
        }
        case NSTAT_MSG_TYPE_SRC_COUNTS: {
            nstat_msg_src_counts m;
            if (hdr.length >= sizeof(m)) {
                memcpy(&m, buf + off, sizeof(m));
                handle_counts(c, &m);
            }
            break;
        }
        case NSTAT_MSG_TYPE_SUCCESS:
            if (hdr.context == context) {
                done = 1;
                *more = (hdr.flags & NSTAT_MSG_HDR_FLAG_CONTINUATION) != 0;
            }
            break;
        case NSTAT_MSG_TYPE_ERROR:
            if (hdr.context == context) {
                nstat_msg_error m;
                memcpy(&m, buf + off, sizeof(m) <= hdr.length ? sizeof(m) : hdr.length);
                done = 1;
                *more = 0;
                *err = (hdr.length >= sizeof(m)) ? (int)m.error : EIO;
            }
            break;
        default:
            break;
        }
        off += hdr.length;
    }
    return done;
}

static int send_msg(cn_ctx *c, const void *msg, size_t len) {
    return send(c->fd, msg, len, 0) < 0 ? errno : 0;
}

/// Sends `req` and reads until the kernel acknowledges it, issuing follow-up
/// requests while the kernel reports more fragments.
static int run_request(cn_ctx *c, nstat_msg_hdr *req, size_t req_len, int fragmented) {
    uint64_t context = ++c->next_context;
    req->context = context;
    if (fragmented) req->flags |= NSTAT_MSG_HDR_FLAG_CONTINUATION;
    int rc = send_msg(c, req, req_len);
    if (rc) return rc;
    uint8_t buf[65536];
    for (;;) {
        ssize_t n = recv(c->fd, buf, sizeof(buf), 0);
        if (n < 0) return errno == EAGAIN ? ETIMEDOUT : errno;
        if (n == 0) return EPIPE;
        int more = 0, err = 0;
        if (handle_buffer(c, buf, (size_t)n, context, &more, &err)) {
            if (err) return err;
            if (!more) return 0;
            rc = send_msg(c, req, req_len);
            if (rc) return rc;
        }
    }
}

// MARK: - Public API

cn_ctx *cn_open(int *err) {
    cn_ctx *c = calloc(1, sizeof(cn_ctx));
    if (!c) { *err = ENOMEM; return NULL; }
    c->capacity = 256;
    c->slots = calloc(c->capacity, sizeof(entry));
    c->fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (!c->slots || c->fd < 0) { *err = c->fd < 0 ? errno : ENOMEM; cn_close(c); return NULL; }

    struct ctl_info info;
    memset(&info, 0, sizeof(info));
    strlcpy(info.ctl_name, NET_STAT_CONTROL_NAME, sizeof(info.ctl_name));
    if (ioctl(c->fd, CTLIOCGINFO, &info) != 0) { *err = errno; cn_close(c); return NULL; }

    struct sockaddr_ctl addr;
    memset(&addr, 0, sizeof(addr));
    addr.sc_len = sizeof(addr);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    addr.sc_id = info.ctl_id;
    if (connect(c->fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { *err = errno; cn_close(c); return NULL; }

    int rcvbuf = 1 << 20;
    setsockopt(c->fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(c->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    nstat_msg_add_all_srcs add;
    memset(&add, 0, sizeof(add));
    add.hdr.type = NSTAT_MSG_TYPE_ADD_ALL_SRCS;
    add.hdr.length = sizeof(add);
    add.provider = NSTAT_PROVIDER_TCP_KERNEL;
    int rc = run_request(c, &add.hdr, sizeof(add), 0);
    if (rc) { *err = rc; cn_close(c); return NULL; }
    return c;
}

void cn_close(cn_ctx *c) {
    if (!c) return;
    if (c->fd >= 0) close(c->fd);
    free(c->slots);
    free(c);
}

int cn_sample_now(cn_ctx *c, cn_sample *out) {
    memset(&c->acc, 0, sizeof(c->acc));

    nstat_msg_query_src_req q;
    memset(&q, 0, sizeof(q));
    q.hdr.type = NSTAT_MSG_TYPE_QUERY_SRC;
    q.hdr.length = sizeof(q);
    q.srcref = NSTAT_SRC_REF_ALL;
    int rc = run_request(c, &q.hdr, sizeof(q), 1);
    if (rc) return rc;

    if (!c->primed) {
        c->primed = 1;
        memset(&c->acc, 0, sizeof(c->acc));
    }
    *out = c->acc;
    return 0;
}

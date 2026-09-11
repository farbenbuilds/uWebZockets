#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netinet/in.h>
#endif
#include <openssl/base.h>
#undef OPENSSL_GNUC_CLANG_PRAGMA
#define OPENSSL_GNUC_CLANG_PRAGMA(arg)

#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <lsxpack_header.h>
#include <lsquic.h>
#include <libdeflate.h>
#include <zlib.h>

/* translate-c cannot represent lsxpack_header's 8-bit enum bitfield. */
struct uz_lsxpack_header {
    char *buf;
    uint32_t name_hash;
    uint32_t nameval_hash;
    lsxpack_offset_t name_offset;
    lsxpack_offset_t val_offset;
    lsxpack_strlen_t name_len;
    lsxpack_strlen_t val_len;
    uint16_t chain_next_idx;
    uint8_t hpack_index;
    uint8_t qpack_index;
    uint8_t app_index;
#ifdef _WIN32
    uint8_t _pad1[3];
    uint32_t flags;
    uint8_t indexed_type;
    uint8_t dec_overhead;
    uint8_t _pad2[6];
#else
    uint8_t flags;
    uint8_t indexed_type;
    uint8_t dec_overhead;
#endif
};

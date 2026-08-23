#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>
#include "../vendor/boringssl/include/openssl/base.h"
#undef OPENSSL_GNUC_CLANG_PRAGMA
#define OPENSSL_GNUC_CLANG_PRAGMA(arg)

#include "../vendor/boringssl/include/openssl/ssl.h"
#include "../vendor/boringssl/include/openssl/crypto.h"
#include "../vendor/lsquic/include/lsquic.h"
#include "../vendor/libdeflate/libdeflate.h"

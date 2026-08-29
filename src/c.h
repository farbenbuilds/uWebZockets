#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/base.h>
#undef OPENSSL_GNUC_CLANG_PRAGMA
#define OPENSSL_GNUC_CLANG_PRAGMA(arg)

#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <lsquic.h>
#include <libdeflate.h>

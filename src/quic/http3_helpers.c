#include <stdio.h>
#include <lsquic.h>
#include <lsxpack_header.h>
#include <stdlib.h>
#include <string.h>

void send_h3_response(lsquic_stream_t *stream, const char *body, size_t body_len) {
    struct lsxpack_header hdrs[3];

    lsxpack_header_set_offset2(&hdrs[0], ":status\x00" "200", 0, 7, 8, 3);
    lsxpack_header_set_offset2(&hdrs[1], "server\x00" "uWebZockets", 0, 6, 7, 11);
    lsxpack_header_set_offset2(&hdrs[2], "content-type\x00" "text/plain", 0, 12, 13, 10);

    struct lsquic_http_headers headers = {
        .count = 3,
        .headers = hdrs,
    };

    lsquic_stream_send_headers(stream, &headers, 0);
    lsquic_stream_write(stream, body, body_len);
    lsquic_stream_close(stream);
}

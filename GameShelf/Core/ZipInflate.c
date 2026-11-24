//
//  ZipInflate.c
//  GameShelf
//

#include "ZipInflate.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

struct gs_inflater {
    z_stream stream;
    int ended;
};

gs_inflater *gs_inflater_new(void) {
    gs_inflater *inf = (gs_inflater *)calloc(1, sizeof(gs_inflater));
    if (!inf) return NULL;
    memset(&inf->stream, 0, sizeof(inf->stream));
    // -15 = raw deflate：ZIP 里没有 zlib 的 2 字节头和 adler32 尾巴
    if (inflateInit2(&inf->stream, -15) != Z_OK) {
        free(inf);
        return NULL;
    }
    inf->ended = 0;
    return inf;
}

void gs_inflater_free(gs_inflater *inf) {
    if (!inf) return;
    inflateEnd(&inf->stream);
    free(inf);
}

int gs_inflater_push(gs_inflater *inf,
                     const uint8_t *in, size_t inLen, size_t *inUsed,
                     uint8_t *out, size_t outCap, size_t *outUsed) {
    if (!inf) return -1;
    if (inUsed) *inUsed = 0;
    if (outUsed) *outUsed = 0;
    if (inf->ended) return 0;

    inf->stream.next_in = (Bytef *)in;
    inf->stream.avail_in = (uInt)inLen;
    inf->stream.next_out = (Bytef *)out;
    inf->stream.avail_out = (uInt)outCap;

    int rc = inflate(&inf->stream, Z_NO_FLUSH);

    if (inUsed) *inUsed = inLen - (size_t)inf->stream.avail_in;
    if (outUsed) *outUsed = outCap - (size_t)inf->stream.avail_out;

    if (rc == Z_STREAM_END) {
        inf->ended = 1;
        return 0;
    }
    if (rc == Z_OK || rc == Z_BUF_ERROR) return 1;
    return -1;
}

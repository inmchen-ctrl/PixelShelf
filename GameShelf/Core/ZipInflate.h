//
//  ZipInflate.h
//  GameShelf
//
//  ZIP 用的是 raw deflate（没有 zlib 头），系统的 Compression 框架只有一次性
//  API（compression_decode_buffer），几百 MB 的条目必须能边解边写。
//  这里用 zlib 的流式接口做一层最小封装：init / push / free。
//

#ifndef GS_ZIP_INFLATE_H
#define GS_ZIP_INFLATE_H

#include <stddef.h>
#include <stdint.h>

typedef struct gs_inflater gs_inflater;

/// 新建一个 raw deflate 解压器（windowBits = -15）。失败返回 NULL。
gs_inflater *gs_inflater_new(void);

/// 释放。
void gs_inflater_free(gs_inflater *inf);

/// 推一段输入，产出最多 outCap 字节。
/// 返回 0 = 流已结束；1 = 还可以继续喂；-1 = 数据损坏。
/// inUsed / outUsed 为本次实际消耗与产出的字节数。
int gs_inflater_push(gs_inflater *inf,
                     const uint8_t *in, size_t inLen, size_t *inUsed,
                     uint8_t *out, size_t outCap, size_t *outUsed);

#endif /* GS_ZIP_INFLATE_H */

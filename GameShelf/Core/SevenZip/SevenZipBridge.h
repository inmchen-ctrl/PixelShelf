//
//  SevenZipBridge.h
//  像素抽屉
//
//  LZMA SDK 的 7z 只读接口，供 Swift 调用。底层用的是 Igor Pavlov 的公有领域实现
//  （C/7zDec.c、C/7zArcIn.c 等，见同目录 LZMA-SDK.txt），这里只做三件事：
//  把 POSIX 文件句柄包成一个 ILookInStream、把条目名转成 UTF-8、把解出的
//  数据块写进文件描述符。7z 复杂的文件夹 / coder 图解析全部交给 SDK。
//

#ifndef SEVEN_ZIP_BRIDGE_H
#define SEVEN_ZIP_BRIDGE_H

#include <stdint.h>

/// 与 SzArEx 的 SRes 语义对齐，上层据此选文案
enum {
    GS7Z_OK = 0,
    GS7Z_ERR_OPEN = 1,          // 打不开文件
    GS7Z_ERR_NOT_ARCHIVE = 2,   // 不是 7z（签名不符）
    GS7Z_ERR_UNSUPPORTED = 3,   // coder 不认识（含 AES 加密条目）
    GS7Z_ERR_CRC = 4,           // 数据校验失败
    GS7Z_ERR_MEM = 5,           // 内存不足
    GS7Z_ERR_READ = 6,          // 读盘失败
    GS7Z_ERR_ARCHIVE = 7,       // 结构损坏
    GS7Z_ERR_BLOCK_TOO_BIG = 8, // 固实块超过内存上限
};

typedef struct gs7z gs7z;

/// 打开归档。失败时仍返回句柄，用 gs7z_error() 取原因，用完照常 close。
gs7z *gs7z_open(const char *path);
void gs7z_close(gs7z *h);

int32_t gs7z_error(const gs7z *h);
uint64_t gs7z_count(const gs7z *h);

/// 归档里是否含加密条目（含头部加密时打不开，另由 error 体现）
int32_t gs7z_is_encrypted(const gs7z *h);

int32_t gs7z_is_dir(const gs7z *h, uint64_t index);
uint64_t gs7z_size(const gs7z *h, uint64_t index);

/// UTF-8 条目名，指针在句柄内，直到下一次调用 gs7z_name 前有效
const char *gs7z_name(const gs7z *h, uint64_t index);

/// 解出单个条目写到 fd；written 返回实际字节数（可为 NULL）
int32_t gs7z_extract(gs7z *h, uint64_t index, int fd, uint64_t *written);

/// 解到新分配的内存（由 gs7z_free 释放），供小文件读取用
int32_t gs7z_extract_bytes(gs7z *h, uint64_t index, uint8_t **out, uint64_t *size);
void gs7z_free(void *p);

#endif /* SEVEN_ZIP_BRIDGE_H */

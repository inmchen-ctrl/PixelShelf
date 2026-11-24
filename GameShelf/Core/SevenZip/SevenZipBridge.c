//
//  SevenZipBridge.c
//  像素抽屉
//
//  把 7-Zip 的 C 接口（公有领域）包成一层扁平 API。设计上只依赖 POSIX，
//  不用官方 7zFile.c（那份要为 Win32 兼容埋一堆宏）。
//

#include "SevenZipBridge.h"

#include "7z.h"
#include "7zCrc.h"
#include "Alloc.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/// 固实块解出来要整块进内存，超过这个体积宁可报错也不让系统杀进程
#define GS7Z_BLOCK_LIMIT ((UInt64)1200 * 1024 * 1024)
/// LookToRead 的预读窗口
#define GS7Z_LOOK_BUF ((size_t)1 << 18)

#define GS7Z_AES_METHOD_ID 0x06F10701u

typedef struct {
    ISeekInStream vt;
    int fd;
} GSFileStream;

struct gs7z {
    GSFileStream fs;
    CLookToRead2 look;
    CSzArEx db;
    Byte *outBuf;
    size_t outBufSize;
    UInt32 blockIndex;
    int32_t err;
    int32_t encrypted;
    char *nameBuf;
    size_t nameBufCap;
};

// MARK: - 文件流

static SRes GSFile_Read(ISeekInStreamPtr p, void *buf, size_t *size) {
    GSFileStream *s = (GSFileStream *)p;
    ssize_t n = read(s->fd, buf, *size);
    if (n < 0) {
        *size = 0;
        return SZ_ERROR_READ;
    }
    *size = (size_t)n;
    return SZ_OK;
}

static SRes GSFile_Seek(ISeekInStreamPtr p, Int64 *pos, ESzSeek origin) {
    GSFileStream *s = (GSFileStream *)p;
    int whence = SEEK_SET;
    if (origin == SZ_SEEK_CUR) whence = SEEK_CUR;
    else if (origin == SZ_SEEK_END) whence = SEEK_END;

    off_t r = lseek(s->fd, (off_t)(*pos), whence);
    if (r < 0) return SZ_ERROR_READ;
    *pos = (Int64)r;
    return SZ_OK;
}

static void GSFileStream_Init(GSFileStream *s, int fd) {
    s->vt.Read = GSFile_Read;
    s->vt.Seek = GSFile_Seek;
    s->fd = fd;
}

// MARK: - 错误映射

static int32_t GSErrorFromSRes(SRes res) {
    switch (res) {
        case SZ_OK: return GS7Z_OK;
        case SZ_ERROR_NO_ARCHIVE:
        case SZ_ERROR_ARCHIVE: return GS7Z_ERR_ARCHIVE;
        case SZ_ERROR_UNSUPPORTED: return GS7Z_ERR_UNSUPPORTED;
        case SZ_ERROR_CRC:
        case SZ_ERROR_DATA: return GS7Z_ERR_CRC;
        case SZ_ERROR_MEM: return GS7Z_ERR_MEM;
        case SZ_ERROR_READ:
        case SZ_ERROR_INPUT_EOF: return GS7Z_ERR_READ;
        default: return GS7Z_ERR_ARCHIVE;
    }
}

// MARK: - 加密探测

/// 逐个文件夹解析 coder 列表，出现 AES 方法即认定有加密条目
static int32_t GSScanEncrypted(const CSzArEx *db) {
    const CSzAr *ar = &db->db;
    for (UInt32 f = 0; f < ar->NumFolders; f++) {
        CSzData sd;
        sd.Data = ar->CodersData + ar->FoCodersOffsets[f];
        sd.Size = ar->FoCodersOffsets[f + 1] - ar->FoCodersOffsets[f];

        CSzFolder folder;
        if (SzGetNextFolderItem(&folder, &sd) != SZ_OK) continue;
        for (UInt32 c = 0; c < folder.NumCoders; c++) {
            if (folder.Coders[c].MethodID == GS7Z_AES_METHOD_ID) return 1;
        }
    }
    return 0;
}

// MARK: - UTF-16LE → UTF-8

static void GSAppendUtf8(Byte **out, const UInt16 *src, size_t count) {
    Byte *p = *out;
    size_t i = 0;
    while (i < count) {
        UInt32 cp = src[i++];
        if (cp >= 0xD800 && cp <= 0xDBFF && i < count) {
            UInt32 lo = src[i];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i++;
            }
        }
        if (cp < 0x80) {
            *p++ = (Byte)cp;
        } else if (cp < 0x800) {
            *p++ = (Byte)(0xC0 | (cp >> 6));
            *p++ = (Byte)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            *p++ = (Byte)(0xE0 | (cp >> 12));
            *p++ = (Byte)(0x80 | ((cp >> 6) & 0x3F));
            *p++ = (Byte)(0x80 | (cp & 0x3F));
        } else {
            *p++ = (Byte)(0xF0 | (cp >> 18));
            *p++ = (Byte)(0x80 | ((cp >> 12) & 0x3F));
            *p++ = (Byte)(0x80 | ((cp >> 6) & 0x3F));
            *p++ = (Byte)(0x80 | (cp & 0x3F));
        }
    }
    *p = 0;
    *out = p;
}

// MARK: - 生命周期

void gs7z_close(gs7z *h) {
    if (!h) return;
    SzArEx_Free(&h->db, &g_Alloc);
    free(h->outBuf);
    free(h->nameBuf);
    free(h->look.buf);
    if (h->fs.fd >= 0) close(h->fs.fd);
    free(h);
}

gs7z *gs7z_open(const char *path) {
    gs7z *h = (gs7z *)calloc(1, sizeof(gs7z));
    if (!h) return NULL;
    h->fs.fd = -1;
    h->err = GS7Z_ERR_OPEN;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return h;
    h->fs.fd = fd;
    GSFileStream_Init(&h->fs, fd);
    SzArEx_Init(&h->db);

    h->look.buf = (Byte *)malloc(GS7Z_LOOK_BUF);
    if (!h->look.buf) {
        h->err = GS7Z_ERR_MEM;
        return h;
    }
    LookToRead2_CreateVTable(&h->look, False);
    h->look.bufSize = GS7Z_LOOK_BUF;
    h->look.realStream = &h->fs.vt;
    LookToRead2_INIT(&h->look);

    CrcGenerateTable();

    SRes res = SzArEx_Open(&h->db, &h->look.vt, &g_Alloc, &g_Alloc);
    if (res != SZ_OK) {
        h->err = GSErrorFromSRes(res);
        // 头部加密时 SDK 只会给 UNSUPPORTED，这里补一层可辨识的判断
        if (h->err == GS7Z_ERR_UNSUPPORTED) h->encrypted = 1;
        return h;
    }

    h->err = GS7Z_OK;
    h->blockIndex = 0xFFFFFFFF;
    h->encrypted = GSScanEncrypted(&h->db);
    return h;
}

// MARK: - 元信息

int32_t gs7z_error(const gs7z *h) { return h ? h->err : GS7Z_ERR_OPEN; }
uint64_t gs7z_count(const gs7z *h) { return h ? (uint64_t)h->db.NumFiles : 0; }
int32_t gs7z_is_encrypted(const gs7z *h) { return h ? h->encrypted : 0; }

int32_t gs7z_is_dir(const gs7z *h, uint64_t index) {
    if (!h || index >= h->db.NumFiles) return 0;
    return SzArEx_IsDir(&h->db, (size_t)index) ? 1 : 0;
}

uint64_t gs7z_size(const gs7z *h, uint64_t index) {
    if (!h || index >= h->db.NumFiles) return 0;
    return (uint64_t)SzArEx_GetFileSize(&h->db, (size_t)index);
}

const char *gs7z_name(const gs7z *h, uint64_t index) {
    if (!h || index >= h->db.NumFiles) return "";

    size_t len = SzArEx_GetFileNameUtf16(&h->db, (size_t)index, NULL);
    if (len == 0) return "";

    UInt16 *tmp = (UInt16 *)malloc(len * sizeof(UInt16));
    if (!tmp) return "";
    SzArEx_GetFileNameUtf16(&h->db, (size_t)index, tmp);

    // UTF-16 最多 3 字节/单元，留够再加终止符
    size_t need = len * 3 + 1;
    if (need > ((gs7z *)h)->nameBufCap) {
        char *grown = (char *)realloc(((gs7z *)h)->nameBuf, need);
        if (!grown) {
            free(tmp);
            return "";
        }
        ((gs7z *)h)->nameBuf = grown;
        ((gs7z *)h)->nameBufCap = need;
    }

    Byte *out = (Byte *)((gs7z *)h)->nameBuf;
    GSAppendUtf8(&out, tmp, len > 0 ? len - 1 : 0);
    free(tmp);
    return ((gs7z *)h)->nameBuf;
}

// MARK: - 解压

static int32_t GSWriteAll(int fd, const Byte *data, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = write(fd, data + done, size - done);
        if (n <= 0) return GS7Z_ERR_READ;
        done += (size_t)n;
    }
    return GS7Z_OK;
}

int32_t gs7z_extract(gs7z *h, uint64_t index, int fd, uint64_t *written) {
    if (written) *written = 0;
    if (!h || h->err != GS7Z_OK) return h ? h->err : GS7Z_ERR_OPEN;
    if (index >= h->db.NumFiles) return GS7Z_ERR_ARCHIVE;
    if (SzArEx_IsDir(&h->db, (size_t)index)) return GS7Z_OK;

    UInt32 folder = h->db.FileToFolder[index];
    if (folder < h->db.db.NumFolders) {
        UInt64 blockSize = SzAr_GetFolderUnpackSize(&h->db.db, folder);
        if (blockSize > GS7Z_BLOCK_LIMIT) return GS7Z_ERR_BLOCK_TOO_BIG;
    }

    size_t offset = 0;
    size_t processed = 0;
    SRes res = SzArEx_Extract(&h->db, &h->look.vt, (UInt32)index,
                              &h->blockIndex, &h->outBuf, &h->outBufSize,
                              &offset, &processed, &g_Alloc, &g_Alloc);
    if (res != SZ_OK) return GSErrorFromSRes(res);

    int32_t w = GSWriteAll(fd, h->outBuf + offset, processed);
    if (w != GS7Z_OK) return w;
    if (written) *written = (uint64_t)processed;
    return GS7Z_OK;
}

int32_t gs7z_extract_bytes(gs7z *h, uint64_t index, uint8_t **out, uint64_t *size) {
    if (out) *out = NULL;
    if (size) *size = 0;
    if (!h || h->err != GS7Z_OK) return h ? h->err : GS7Z_ERR_OPEN;
    if (index >= h->db.NumFiles) return GS7Z_ERR_ARCHIVE;
    if (SzArEx_IsDir(&h->db, (size_t)index)) return GS7Z_OK;

    UInt32 folder = h->db.FileToFolder[index];
    if (folder < h->db.db.NumFolders) {
        UInt64 blockSize = SzAr_GetFolderUnpackSize(&h->db.db, folder);
        if (blockSize > GS7Z_BLOCK_LIMIT) return GS7Z_ERR_BLOCK_TOO_BIG;
    }

    size_t offset = 0;
    size_t processed = 0;
    SRes res = SzArEx_Extract(&h->db, &h->look.vt, (UInt32)index,
                              &h->blockIndex, &h->outBuf, &h->outBufSize,
                              &offset, &processed, &g_Alloc, &g_Alloc);
    if (res != SZ_OK) return GSErrorFromSRes(res);

    if (processed > 0) {
        Byte *copy = (Byte *)malloc(processed);
        if (!copy) return GS7Z_ERR_MEM;
        memcpy(copy, h->outBuf + offset, processed);
        if (out) *out = copy;
        if (size) *size = (uint64_t)processed;
    }
    return GS7Z_OK;
}

void gs7z_free(void *p) { free(p); }

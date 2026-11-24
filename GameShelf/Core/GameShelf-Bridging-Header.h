//
//  GameShelf-Bridging-Header.h
//  Swift ↔ mkxp-z 引擎的 C 桥接。只暴露 app_bridge.h，不引入任何引擎内部头
//  （SDL / SharedState），保持引擎与 UI 层解耦。
//

#import "app_bridge.h"
// 大 zip 的流式解压（raw deflate → zlib 流式接口）
#import "ZipInflate.h"
// 7z 容器（LZMA SDK 公有领域实现）
#import "SevenZip/SevenZipBridge.h"

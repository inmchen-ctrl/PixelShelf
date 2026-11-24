# 第三方组件与许可

像素抽屉（GameShelf，下称「本应用」）在运行游戏时链接或随包分发下列开源项目的
构建产物。本文件列明各组件、版本、许可与上游来源；完整许可证文本以对应上游仓库
发布的版本为准。

## 授权范围

本应用的应用层源代码（`GameShelf/` 目录下的 Swift 文件）依 MIT 许可证发布：

```
Copyright © 2026 inmchen
SPDX-License-Identifier: MIT
```

许可证全文见同目录 `LICENSE`。第三方组件不在该授权范围内，各自遵循下列条款：

- `Engine/mkxp-ios/` 及其静态库 —— mkxp-z（GPL-2.0）及 SDL2、ANGLE、FreeType 等依赖
- `GameShelf/Resources/godot-*-web.zip` —— Godot Engine（MIT）
- `GameShelf/Resources/ruffle-web.zip` —— Ruffle（MIT 或 Apache-2.0）
- `GameShelf/Resources/bg-diamante.png` —— 界面底纹，作者自有素材

## 运行时引擎

| 组件 | 版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| mkxp-z（RGSS / RPG Maker XP·VX·VX Ace 兼容层） | v24 | GPL-2.0-or-later；构建启用 OpenSSL 时产物整体按 GPLv3 | https://github.com/mkxp-z/mkxp-z |
| Godot Engine（Web 导出运行时） | 4.5 / 4.6 | MIT | https://github.com/godotengine/godot |
| Ruffle（Flash / SWF，WebAssembly） | 随包 | MIT 或 Apache-2.0 | https://github.com/ruffle-rs/ruffle |
| Ruby（由 mkxp-z 内嵌） | 1.8 / 1.9 / 3.1 | Ruby License / GPL-2.0 | https://www.ruby-lang.org |

## 图形与多媒体

| 组件 | 许可证 |
| --- | --- |
| ANGLE（EGL / GLES） | BSD-3-Clause |
| SDL2 / SDL2_image / SDL2_ttf / SDL2_sound | zlib |
| FreeType | FTL / GPL-2.0 |
| pixman | MIT |
| libogg / libvorbis / libvorbisfile / libtheora / libtheoradec | BSD-3-Clause |
| OpenAL Soft | LGPL-2.0 |
| FluidSynth | LGPL-2.1 |
| PhysFS | zlib |
| uchardet | MPL-1.1 / GPL-2.0 / LGPL-2.1 |
| OpenSSL（libssl / libcrypto） | Apache-2.0 |
| zlib / bzip2 | zlib / BSD 类 |

## 系统框架

SwiftUI、UIKit、WebKit、AVFoundation、CoreGraphics、Metal、GameController、
CoreHaptics 等由 iOS 提供，不随本应用分发源码。

## 自有素材

- 界面底纹 `bg-diamante.png` 由作者设计并绘制，版权归作者所有，
  随本应用一并分发，不涉及第三方授权。

## 分发合规

分发包内含 mkxp-z（GPL-2.0-or-later，启用 OpenSSL 后产物按 GPLv3）与
OpenAL Soft、FluidSynth 等 LGPL 组件，均为静态链接。

- 以完整安装包形式对外分发时，须提供 mkxp-z 及其 GPL 依赖的对应源码
  （或书面获取方式），并满足 LGPL 的重新链接要求（随包提供可重链接的目标文件）。
- 仅分发应用层源代码时，不涉及上述义务。
- 已知限制：GPLv3 与 App Store 的分发条款存在冲突（FSF 立场，§6 安装信息与
  反附加限制），带 mkxp-z 的完整包不应通过 App Store 分发。

本应用不包含任何游戏本体、素材或破解内容；导入游戏的版权归各自权利人，
使用者应确保拥有合法授权。

## 未包含的第三方素材

- **RPG Maker RTP**（`Engine/mkxp-ios/core/Assets.bundle/RTP`）：版权归 KADOKAWA / Enterbrain，
  授权范围仅限随 RPG Maker 制作并分发的游戏使用。本仓库不收录、不对外分发该目录；
  需要时由使用者从自己持有的 RPG Maker 安装介质中取得。

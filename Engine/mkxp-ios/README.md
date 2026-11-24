# RGSS / RPG Maker VX Ace 兼容分支（mkxp-z on iOS）

## 为什么需要这个分支

GameShelf 的运行时按引擎形态区分：

| 引擎 | 运行时 | 形态 |
|---|---|---|
| RPG Maker MV / MZ | WKWebView | 网页（www/ + js/） |
| Godot | wasm | 网页导出的 wasm 包 |
| **RPG Maker XP / VX / VX Ace** | **mkxp-z（原生）** | **Windows PE + Ruby + DirectX** |

VX Ace 的 exe 游戏是 **RGSS3** 工程：

```
Game.exe            PE32 (Windows x86)
System/RGSS300.dll  PE32 RGSS 运行时
Game.ini            Library=System\RGSS300.dll / Scripts=Data\Scripts.rvdata2
Data/*.rvdata2      Ruby Marshal 数据（未加密时是 04 08 头）
Graphics/ Audio/    散装资源
```

没有 index.html、没有 js/，**完全不是网页工程**，WKWebView 无法执行。唯一可行路径是
[mkxp-z](https://github.com/mkxp-z/mkxp-z)（开源 RGSS 运行时，C++/SDL2/OpenGL）。

上游 mkxp-z 不提供 iOS 目标。这里采用社区维护的 Apple 移动端移植：
[genexix05/mkxp-z-apple-mobile](https://github.com/genexix05/mkxp-z-apple-mobile)
（App Store 上 Empo / Runa 等播放器的引擎），它把引擎改成了「进程常驻 + C 桥接 + ANGLE(Metal)」的形态。

## 产物

跑 `sh build-mkxp-ios.sh` 得到：

```
build/libmkxpz-core.a      引擎核心
build/mkxp18-merged.o      Ruby 1.8 → RGSS1（XP）
build/mkxp19-merged.o      Ruby 1.9 → RGSS2（VX）/ RGSS3（VX Ace）
build/mkxp31-merged.o      Ruby 3.1 → 新版游戏
```

依赖（预编译，`fetch-deps-ios.sh` 自动下载，约 223MB）：
`deps/build-iphoneos-arm64/{lib,include}` 和 `deps/ANGLE/iphoneos`。

> **`core/Assets.bundle/RTP` 不在仓库里**（约 187MB）。那是 RPG Maker 的 Run Time Package，
> 版权归 KADOKAWA / Enterbrain，授权只覆盖「随 RPG Maker 游戏分发」。本地要跑依赖 RTP 的
> 老工程，从自己的 RPG Maker 安装目录把 `Graphics/` 与 `Audio/` 拷进该路径即可。

## 链接参数

```sh
-Wl,-force_load,build/libmkxpz-core.a
build/mkxp18-merged.o build/mkxp19-merged.o build/mkxp31-merged.o
-lSDL2 -lSDL2main -lSDL2_image -lSDL2_sound -lSDL2_ttf
-lfreetype -lpixman-1 -lpng16 -logg -lvorbis -lvorbisfile -ltheora -ltheoradec
-lphysfs -luchardet -lopenal -lssl -lcrypto -lz -lbz2 -liconv
-lANGLE_static -lEGL_static -lGLESv2_static
-framework Foundation -framework UIKit -framework CoreFoundation -framework CoreGraphics
-framework CoreVideo -framework CoreAudio -framework AudioToolbox -framework AVFoundation
-framework Metal -framework QuartzCore -framework GameController -framework CoreMotion -framework IOSurface
-weak_framework CoreBluetooth -weak_framework CoreHaptics -weak_framework OpenGLES
```

注意：

- `mkxp18/19/31-merged.o` **三个必须全带上**——`binding.h` 在运行时按游戏切换 Ruby 版本，少一个就链接失败。
- 链接驱动必须是 `clang++`（引擎、SDL、OpenAL 都是 C++）。

## 宿主桥接接口（`src/app_bridge.h`）

引擎是「进程常驻」模式，和 GameShelf 的用法天然契合：

```c
// 1. App 启动时在后台线程跑引擎 main()，它会阻塞等待游戏路径
//    EngineHost::init() 第一步就是 mkxp_waitForGamePath()

// 2. 用户在库里选游戏后，宿主设置路径，引擎解除等待并启动
void mkxp_setGamePath(const char *path);

// 3. Ruby 版本（由 RGSS 版本决定）
typedef enum { MKXP_RUBY_UNSET=-1, MKXP_RUBY_18=18, MKXP_RUBY_19=19,
               MKXP_RUBY_30=30, MKXP_RUBY_31=31 } MKXPRubyVersion;
void mkxp_setActiveRubyVersion(MKXPRubyVersion v);

// 4. 启动前会话配置（配置目录 / 用户数据目录 / 字体 / 竖屏对齐 / 键盘等）
typedef struct {
    const char *managedConfigDir;
    const char *userDataDirectory;
    const char *sharedFontsDirectory;
    MKXPRubyVersion rubyVersion;
    MKXPSyntaxTransformMode syntaxTransformMode;
    MKXPVerticalAlignment verticalAlignment;
    bool postloadEnabled;
    bool useInGameKeyboard;
    bool joiplayCompat;
    bool networkEnabled;
} MKXPSessionConfig;
void mkxp_applySessionConfig(const MKXPSessionConfig *config);

// 5. 输入：触摸 → 键鼠
void mkxp_injectKeyEvent(int scancode, int pressed);

// 6. 视口 / 安全区
void mkxp_setGameRect(float x, float y, float w, float h);
void mkxp_setSafeAreaInsets(float top, float bottom, float left, float right);

// 7. 取 SDL 的 UIKit 窗口，挂进 SwiftUI
void *mkxp_getSDLUIKitWindow(void);
```

启动流程（上游 Empo 的用法）：

```
UIApplicationMain
   └─ SDL 线程跑 main() → EngineHost.init() → mkxp_waitForGamePath() 阻塞
        └─ 宿主 SwiftUI 选游戏 → mkxp_applySessionConfig + mkxp_setGamePath
             └─ 引擎建 ANGLE(EGL) 上下文 → 跑 RGSS 脚本 → 出画面
```

宿主侧的分工：`PackageInspector` 识别 RGSS 工程（`.rvdata2` + `Game.ini` 或
`.rgss3a` / `.rgssad` 加密包），导入时整目录解到沙盒并记为 `.rgss` 引擎；
`GamePlayerView` 把路径喂给 `mkxp_setGamePath`，按版本选 `MKXP_RUBY_19`（VX Ace）等，
再把触摸映射到 `mkxp_injectKeyEvent`（方向键 / Z 确认 / X 取消 / Shift 冲刺）。
RGSS 走 mkxp 自己的 FS 层，`GameSchemeHandler` 不参与。

## 已知坑

- **hmode7 是 SSH 子模块**（`git@github.com:...`），无 SSH key 会卡住。构建脚本已改成 https 直取。
- 预编译依赖按 **iOS 26.0** 构建，链接到更低 `min-os` 会有一堆 `was built for newer 'iOS' version`
  警告（不影响运行）。构建时用 `min-os 17.0` 只是降低警告噪音，不是硬要求。
- ANGLE 是唯一的渲染后端（iOS 12 起 OpenGL ES 被废弃，旧的 EAGL 路径会崩）。
- 引擎不允许退出进程（App Store 2.5.1），`Kernel.exit!` 会被重定向。
- 存档在游戏目录下的 `Save*.rvdata2`，沙盒对该目录需可写。

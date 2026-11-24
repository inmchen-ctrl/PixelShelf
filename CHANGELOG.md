# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 新增
- 加密 zip 导入：ZipCrypto 与传统之外的 WinZip AE-1/AE-2（AES-128/192/256）都能解，
  导入时弹密码框，密码错误原地重试；解压全程流式，内存占用与明文包一致
- 包内多层目录自动定位：外层广告壳、说明目录被排除，按引擎脚本 / 入口 / 资源目录打分挑真游戏根，
  分数接近才让用户选

### 变更
- 移除全部调试启动参数（`-gs-*`）及配套的自检、抓屏、FS dump 代码，仓库不再携带测试脚手架
- 工程文件清空 `DEVELOPMENT_TEAM`，Bundle Identifier 改为 `com.inmchen.gameshelf`；克隆后需在 Xcode 里选自己的 Team
- RPG Maker RTP 素材不再入库（版权归 KADOKAWA，授权只覆盖随游戏分发），补齐方式写进构建说明
- 文档中的开发过程记录、真实游戏名、个人签名信息一并清理

### 计划中
- 拆分 `GameWebView.swift`（当前 2870 行）
- 为引擎判定与 APNG 抽帧补上单元测试
- 支持自定义 Bundle Identifier 而无需手改工程文件

## [0.1.0] - 2026-11-24

首个公开版本。

### 新增
- 游戏库：磁贴墙、分类、搜索、封面裁切；导入 `.apk` / `.zip` / `.xapk` / `.apks`
- 引擎判定与入口识别，网页工程多入口选择
- RPG Maker MV / MZ 运行时（WKWebView + 自定义 scheme）
- RGSS 运行时（mkxp-z，Ruby 1.8 / 1.9 / 3.1）
- Godot 4 运行时（内置 4.5 / 4.6 web 导出包，设备端重打包 PCK）
- Flash 运行时（Ruffle），SWF 头解析
- APNG 块级抽帧：降低逐帧动画的峰值内存，保持分辨率与总时长
- 图片缓存回收：RPG Maker MZ 的 `ImageManager._cache` 增量清理
- WebAssembly 内存配额压制
- 启动看门狗：阶段打点、超时兜底、可读的失败原因
- 网络隔离：默认阻断全部对外请求，可在设置中关闭
- 虚拟手柄（可拖拽布局）与物理手柄映射、震动反馈、输入自检
- 每个游戏的存档导出与导入
- 翻译字典挂载：游戏内自带翻译或导入外部 JSON，单份生效、重复覆盖
- 设置页：APNG 抽帧、缓存回收、网络隔离、控制台初始状态
- 关于页：作者、许可与第三方组件声明
- 诊断日志落盘（`gs_diag.log`）

### 已知问题
- 不支持 JIT；Unity、Ren'Py 仅识别不可运行
- 部分游戏依赖远程 CDN 资源，网络隔离下会加载失败
- 缺少单元测试与 CI
- 完整包因内置 mkxp-z 受 GPL-3.0 约束

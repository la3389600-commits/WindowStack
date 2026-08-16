# WindowStack · 窗口叠放

一款原生 macOS 窗口整理工具，支持平铺、叠放、触控板横滑切换及一键恢复。项目使用 Swift、AppKit 与公开的 Accessibility API 实现，不注入其他进程，也不要求关闭 SIP。

## 功能

- **平铺模式**：将当前屏幕的普通窗口统一尺寸并横向排列，窗口较多时自动分页。
- **叠放模式**：窗口按对角线层叠，通过横滑切换前台窗口。
- **两种交互手感**：逐组切换，或跟手滑动 + 惯性 + 吸附。
- **流畅动画**：由显示刷新率驱动动画；Accessibility 写入按应用异步排队，避免慢应用阻塞主线程。
- **自定义尺寸**：平铺和叠放分别设置宽高比例，支持数值输入、预览与应用。
- **可调过渡**：逐组切换使用纯黑方向渐变遮挡窗口交换。
- **全局快捷键**：默认支持平铺、叠放和恢复，也可自行修改。
- **Finder 扩展**：可以从桌面右键菜单直接执行窗口操作。
- **隐私友好**：不联网、不收集数据，所有设置只保存在本机。

## 系统要求

- macOS 13 Ventura 或更高版本
- 辅助功能权限（用于读取、移动和调整其他应用的窗口）
- 从源码构建需要 Xcode Command Line Tools

## 默认快捷键

| 操作 | 快捷键 |
| --- | --- |
| 平铺窗口 | `⇧⌘T` |
| 叠放窗口 | `⇧⌘C` |
| 恢复布局 | `⇧⌘R` |

如果快捷键已被其他应用占用，控制面板会显示注册失败提示。

## 使用

1. 构建应用，或取得可信来源提供的构建产物。
2. 将 `WindowStack.app` 移到 `/Applications` 后启动。
3. 前往“系统设置 → 隐私与安全性 → 辅助功能”，允许“窗口叠放”控制其他应用。
4. 使用控制面板、菜单栏图标或全局快捷键排列窗口。
5. 横向滑动触控板或鼠标滚轮，在窗口页或叠放窗口之间切换。
6. 使用“恢复布局”回到本次运行期间记录的原始位置。

应用只处理当前屏幕上的普通窗口，并跳过已最小化、隐藏、全屏及尺寸过小的窗口。

## 从源码构建

```bash
git clone https://github.com/la3389600-commits/WindowStack.git
cd WindowStack
./build.sh
```

构建产物位于 `dist/WindowStack.app`。构建脚本会：

1. 直接使用 `swiftc` 编译主应用和 Finder Sync 扩展；
2. 首次运行时在 `build/keychain/` 创建仅供本项目使用的本地自签名证书；
3. 签名应用和扩展。

构建脚本不会上传证书或私钥；`build/keychain/` 与 `dist/` 均已被 Git 忽略。

## 启用 Finder 右键菜单

在“系统设置 → 隐私与安全性 → 扩展 → 添加的扩展”中启用“窗口叠放右键菜单”。也可以手动注册：

```bash
pluginkit -a /Applications/WindowStack.app/Contents/PlugIns/WindowStackFinderSync.appex
pluginkit -e use -i com.local.WindowStack.FinderSync
```

若系统中曾同时运行开发目录和 `/Applications` 下的应用，可能残留重复扩展。注销开发版本后重新注册正式路径即可。

## 重新生成应用图标

```bash
mkdir -p build/WindowStack.iconset
swift build/scripts/generate_icon.swift build/WindowStack.iconset
iconutil -c icns build/WindowStack.iconset \
  -o WindowStack/Resources/WindowStack.icns
```

## 项目结构

```text
WindowStack/
├── Sources/                 # AppKit 主应用、窗口排列、动画与快捷键
└── Resources/               # Info.plist、权限配置与应用图标
build/scripts/               # 可复现的图标生成脚本
Tests/                       # 需要辅助功能权限的手动集成测试
build.sh                     # 无第三方依赖的构建脚本
```

## 安全与隐私

WindowStack 只通过 macOS Accessibility API 读取和修改窗口位置、尺寸及层级。它不会读取窗口内容，不包含遥测、广告、账户系统或网络请求。公开发布的源码构建使用本地自签名证书；macOS 可能提示应用未经过 Apple 公证。

发现安全问题时，请不要公开披露利用细节，改用仓库的 GitHub Security Advisory 私下报告。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。

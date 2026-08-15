# 窗口叠放

一个 macOS 窗口整理小工具：默认把当前屏幕上可见的普通应用窗口平铺成相同尺寸；也保留叠放模式。双击打开后会出现控制面板，菜单栏图标和桌面右键菜单都可以一键操作。

## 使用

1. 双击 `dist/WindowStack.app` 启动，会出现“窗口叠放”控制面板。
2. 第一次执行平铺/叠放时，如果系统弹出辅助功能授权提示，请到“系统设置 > 隐私与安全性 > 辅助功能”勾选 `WindowStack`。
3. 点击“平铺窗口”，或左键菜单栏图标，即可把当前屏幕窗口平铺成相同尺寸。
4. 也可以直接在桌面空白处右键，选择“平铺窗口 / 叠放窗口 / 恢复布局”。
5. 点击“恢复布局”或右键菜单栏图标可以恢复上次布局；右键菜单里也可以退出。
6. 平铺后如果窗口横向排满一屏，使用触控板横向滑动或鼠标横向滚轮即可左右平移；点“恢复布局”会退出横向滚动模式。

如果桌面右键菜单没有出现“窗口叠放”项，请到“系统设置 > 隐私与安全性 > 扩展 > 添加的扩展”，勾选 `窗口叠放右键菜单`。

如果之前同时运行过 `dist/WindowStack.app` 和 `/Applications/WindowStack.app`，系统可能注册了旧的重复扩展。可先注销旧路径再重启 Finder：

```bash
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$lsregister" -u "$PWD/dist/WindowStack.app"
pluginkit -r "$PWD/dist/WindowStack.app/Contents/PlugIns/WindowStackFinderSync.appex"
"$lsregister" -f /Applications/WindowStack.app
pluginkit -a /Applications/WindowStack.app/Contents/PlugIns/WindowStackFinderSync.appex
pluginkit -e use -i com.local.WindowStack.FinderSync
killall Finder
```

## 行为

- 默认平铺：窗口横向排列，高度为桌面高度的一半并垂直居中；窗口较多时分页显示，各页放在屏幕外的真实位置，横向滑动时整页跟手平移进入，如同原生分页。
- 叠放：窗口按对角线层叠；双指横向滑动时相邻两张连续互滑，松手吸附切换当前前台窗口。
- 横滑手感：内容跟手移动 → 松手惯性滑行 → 吸附到最近一页/最近一张；快速甩动按速度翻页，慢拖不足半屏自动回弹。惯性（momentum）事件被忽略，不再连跳多页。
- 横向滚动只响应光标位于排列区域内的手势，不会劫持其他 app 的横滚。
- 平铺、叠放、恢复和横向滚动都以 30Hz 同步、按位移变化量过滤的平滑动效执行（减少辅助功能接口调用，动画不掉帧）。
- 备用叠放：统一尺寸并按对角线错落层叠。
- 只处理当前屏幕上的普通应用窗口。
- 跳过已最小化、隐藏、全屏和小于 100 x 60 的窗口。
- 恢复布局只在当前程序运行期间有效。

## 重新构建

```bash
./build.sh
```

构建产物会写入 `dist/WindowStack.app`。
构建脚本会同时生成 Finder Sync 右键菜单扩展，并使用本机自签名证书签名；重复构建不会覆盖已有证书。把 `dist/WindowStack.app` 复制到“应用程序”后，注册并启用扩展：

```bash
pluginkit -a /Applications/WindowStack.app/Contents/PlugIns/WindowStackFinderSync.appex
pluginkit -e use -i com.local.WindowStack.FinderSync
```

## GitHub 上的同类工具

- [Fanned](https://github.com/lxyang777/fanned)：同样是“一键把所有窗口按对角线层叠”的 macOS 菜单栏工具。
- [Rectangle](https://github.com/rxhanson/Rectangle)：更通用的 macOS 窗口布局工具。
- [Hammerspoon](https://github.com/Hammerspoon/hammerspoon)：可脚本化控制窗口和系统能力。
- [yabai](https://github.com/koekeishiya/yabai)：面向高级用户的平铺窗口管理器。

# Apple Aerial Controller

macOS 原生菜单栏航拍壁纸控制器，使用 Swift、SwiftUI、AppKit 和 AVFoundation。当前版本 **0.1.6**，面向单个内建显示屏，使用本机已经下载的 Apple 航拍资源。

## 功能

- 自由组合自然景观、水下景观、城市景观和地球四类航拍。
- 15、30、60、120 分钟或自定义正整数分钟轮换；“下一张”立即随机切换。
- 每次切换从头完整播放视频，结束后停在最后一帧；也可重新播放当前航拍。
- 保留旧画面直到新首帧就绪，立即开始播放，并在后面同步原生壁纸，减少灰屏和首帧等待。
- 显示各类已下载数量、可轮换数量和本地文件大小；刷新资源不会下载或删除视频。
- 保存分类、间隔和轮换状态；下次打开检查接管状态后恢复完整倒计时。
- 睡眠或退出期间错过的切换跳过，不连续补切。视频仍在播放时到期也跳过，不截断视频。
- 备份第一次接管前的原生选择，支持恢复；发现外部壁纸设置变更后停止写入。

所有控件位于菜单栏弹出面板，不打开独立控制窗口。目前不包含“上一张”、视频暂停/继续、多屏或自动下载。

## 构建和运行

需要 Apple Silicon Mac、macOS 26、可用的 Swift 6 工具链，以及本机已下载的 Apple 航拍视频。实机验收环境为 macOS 26.7.1、Swift 6.3.3 和 SDK 26.5；其他版本尚未验证。

```sh
bash scripts/build.sh
open build/AerialController.app
```

脚本默认使用 `/usr/bin/swiftc` 和 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，构建 arm64、最低部署 macOS 26.0 的本地 ad hoc 签名应用。可以用环境变量指定兼容工具链：

```sh
AERIAL_SDK="$(xcrun --sdk macosx --show-sdk-path)" bash scripts/build.sh
```

`AERIAL_SWIFTC` 可指定编译器；SDK 和编译器需相互兼容。没有正式开发者签名或 notarization，目前以源码构建为主。

首次打开保持暂停。先勾选分类和间隔，再点击“开始轮换”。“暂停轮换”保存暂停状态；“退出”保留此前轮换意图。“返回原生画面”撤掉桌面播放层。

需要登录后自动继续时，将应用固定放在 `/Applications/AerialController.app`，并通过“系统设置 → 通用 → 登录项与扩展 → 登录时打开”添加应用。macOS 负责启动，应用负责恢复轮换状态；启动不会立即切图。

## 实现与边界

```text
Menu Bar → Aerial Catalog → Custom Playlist → Timer → Native Switcher
                                                  ↘ Desktop Video Player
```

资源索引读取 Apple 本地 manifest、分类元数据及视频文件。当前已验证主视频目录为 `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`。四类自定义播放池不受 Apple manifest 的 `includeInShuffle` 标记限制，但不会修改 manifest。备用 `4KSDR240FPS/` 文件计入下载大小，尚未通过原生切换验收，因此不纳入轮换。

原生切换依赖 **非公开的用户 Wallpaper Store 和原生服务重载**。写入前检查配置结构、单屏作用域、接管状态和外部变更；首次写入前备份，并要求目标由新的原生 provider 进程或新打开的视频文件验证加载。此实现可能随 macOS 更新失效，不关闭 SIP、不修改受保护系统文件。

桌面完整播放使用公开 AppKit + AVFoundation，在桌面与图标之间显示不接收点击、不抢焦点的窗口。这是应用自己的视频播放层；Apple 仍负责锁屏动画，两者时间线不完全同步，锁屏/解锁后可能出现画面跳转。视频自然结束后保留暂停播放器，直到返回原生画面、下一次切换或退出。公开会话通知无法精确覆盖每次锁屏；睡眠、Space 切换和显示器变化会撤掉播放层。

持帧期间尚未实时监听系统壁纸设置；外部改图后可点击“返回原生画面”。准备视频最多等待 8 秒；播放中连续 30 秒没有媒体进展才按异常处理，不限制正常视频总时长。

偏好设置和接管日志保存在 `~/Library/Application Support/AppleAerialController/`。首次接管的备份不因升级覆盖。构建输出、系统配置、备份和 Apple 视频均不随仓库分发。

## 验证

```sh
bash scripts/check.sh
bash scripts/check-startup.sh
```

`check.sh` 包含资源、调度、原生切换模型和偏好设置检查，也读取本机实际资源清单；缺少相应 Apple manifest 的机器不能直接完成 live 资源检查。`check-startup.sh` 需要 AppKit 图形会话和现有 Wallpaper Store，在被忽略的 `build/` 中创建合成接管记录。两者不主动切换壁纸，启动检查对比真实 Store 前后字节。

0.1.6 本机构建与严格签名检查通过，14 项启动检查通过；临时离线集成检查使用真实 AppModel 和 fake 原生/媒体边界，14 项通过，覆盖提前播放、错误分流、提前结束持帧、取消/退出和计时保护。安装前后真实 Store 与偏好设置保持一致。用户手动验收接受了切换和播放效果。

这些验证不代表全部素材完整解码、全部系统版本、多屏、实际系统登录或长时运行均已通过。原始实机配置和调试日志不公开。

## 源码

```text
Sources/AerialCore/        资源索引、Timer、原生切换与恢复
Sources/AerialController/ 菜单栏、SwiftUI 面板、偏好设置和桌面播放器
Resources/Info.plist       菜单栏应用配置
Tests/                    核心与启动检查
scripts/                  构建和检查脚本
```

## 许可

应用代码采用 [MIT License](LICENSE)。Apple 航拍素材归其权利人所有，不随项目分发。项目与 Apple 无关联。

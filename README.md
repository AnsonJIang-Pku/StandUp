# StandUp 起身

<img src="App/Assets.xcassets/AppIcon.appiconset/StandUp-128.png" width="96" height="96" alt="StandUp 应用图标">

StandUp 1.1.3（Build 5）是离线运行的 macOS 原生菜单栏久坐提醒工具。支持 macOS 13 Ventura 及以上，Bundle ID 为 `com.standup.reminder`。Release 包同时包含 Apple Silicon 和 Intel 架构。

## 安装与使用

1. 从 [GitHub Releases](https://github.com/AnsonJIang-Pku/StandUp/releases/latest) 下载 macOS 通用版 ZIP，解压后将 `StandUp.app` 拖入「应用程序」并双击启动。也可直接运行本地构建生成的 `build/Build/Products/Release/StandUp.app`。
2. 点击菜单栏的 StandUp，在面板里点击「启用系统通知」，然后在 macOS 提示里选择「允许」。如已拒绝，可从面板跳转到系统通知设置。
3. 默认可在工作日 09:00–22:00 点击「开始工作」。每轮工作 30 分钟后，可选择开始活动 3 分钟、稍后 5 分钟提醒或跳过。默认在活动完成后进入下一轮。忽略或关闭通知时，可继续从菜单栏处理本次提醒。
4. 点击齿轮打开设置，切换「计时」「预设」「日程」和「通用」。统计默认开启，登录启动默认关闭。

交付包使用 ad-hoc 签名，尚未经过 Apple 公证。若 macOS 对来自其他设备的副本显示安全提示，确认来源后按「系统设置 → 隐私与安全性」中的提示处理。若打开了构建目录中的副本，安装前先从菜单栏退出该副本。

## 1.1 配置指南

- **计时**。工作、活动和延迟各支持 1–1440 分钟，可输入整数分钟或 `H:MM`（如 `1:15`）。延迟次数可设为不限或 0–9999，0 表示关闭稍后提醒。次数从每轮工作开始时重置。用完后仍可开始活动或跳过。关闭自动开始后，活动完成会回到待开始状态。「恢复默认」会填回默认值，点击「保存计时」后生效。
- **预设**。内置高频活动（20 / 3 / 5）、均衡（30 / 3 / 5）、轻松（45 / 5 / 5）和番茄工作法（25 / 5 / 5），单位为分钟。点击「填入」后可以编辑任意参数，再保存计时配置。编辑后的参数与预设不一致时显示为「自定义」。自定义预设可以创建、重命名、修改和删除。
- **日程**。逐日启用并设置起止时间，或选择全天。结束时间早于开始时间时，须开启「允许跨午夜」。例如周五 22:00 至次日 02:00 由周五规则控制，周六独立关闭也可以运行到 02:00。相同起止时间须改成不同时间，或明确选择全天。关闭「限制提醒时段」后每天都可开始。
- **生效时间**。计时和预设保存后更新全局配置，本轮工作、活动、延迟及自动开始规则仍用启动时的快照。下一轮或点击「重新开始」时读取最新配置。日程保存后立即重新评估，若已在允许时段外，会结束会话并清除提醒。
- **系统时间**。日程按系统时区解释。系统时区变化后重新评估允许时段。遇到夏令时跳过的本地时间，边界移动到下一个有效时刻。重复时间取第一次作为开启边界、最后一次作为结束边界。重叠或连续的允许时段合并，结束边界不包含在允许时段内。

## 从 1.0 升级

退出旧应用后用新版应用包替换它，再启动新版。数据目录沿用 `~/Library/Application Support/StandUp/`。

首次读取 1.0 数据时，应用先把原始 `state.json` 备份为 `state.v1.backup.json`，再原子写入带有 `schemaVersion: 2` 的文件。现有统计、统计开关、会话 ID、阶段、截止时间和暂停状态都会保留。旧会话使用 30 / 3 / 5 分钟、延迟不限和自动开始下一轮，初始全局日程保持工作日 09:00–22:00。

缺失字段使用默认值。若可读部分中有损坏的计时或设置，应用会尝试保留仍能解析的其他数据。替换损坏数据前会保留原文件。备份或迁移写入失败时，应用会提示读取错误，避免覆盖原件。遇到更高版本的数据也会保护原文件。若要退回 1.0，应先退出应用并另存新版数据，再用 1.0 备份恢复原文件。

## 构建与测试

打开 `StandUp.xcodeproj`，选择 StandUp scheme 和本机 Mac，运行或构建。项目使用 Xcode 16 的文件夹同步功能。也可在包含本 README 的目录运行：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project StandUp.xcodeproj -scheme StandUp -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build build
swift test
codesign --verify --deep --strict build/Build/Products/Release/StandUp.app
open build/Build/Products/Release/StandUp.app
```

使用 Xcode 16.2、Swift 6.0.3 和 macOS SDK 15.2 验证构建。核心单元测试通过 SwiftPM 运行。提交构建相关文件到 `main` 或发起相应 PR 时，GitHub Actions 会运行单元测试、构建通用版并校验签名。详见 [测试报告](TEST-REPORT.md) 和 [macOS CI](https://github.com/AnsonJIang-Pku/StandUp/actions/workflows/macos.yml)。

## 项目结构

```text
StandUp/
├── .github/workflows/            macOS 持续集成
├── Design/                       应用图标源文件
├── StandUp.xcodeproj/              原生 macOS 应用工程和共享 scheme
├── App/
│   ├── StandUpApp.swift            SwiftUI MenuBarExtra
│   ├── AppDelegate.swift           应用生命周期和通知回调
│   ├── AppModel.swift              主线程调度、持久化与界面模型
│   ├── Services/                   NSWorkspace、SMAppService
│   ├── Views/                      菜单栏、主面板、设置、统计
│   └── Resources/                  原创 Soft 提示音
├── Package.swift
├── Sources/StandUpCore/
│   ├── Core/                       状态机、事件、时钟注入、日程和默认值
│   ├── Models/                     会话快照、设置、预设、每周日程和统计
│   └── Services/                   通知、原子存储、统计、会话协调
└── Tests/StandUpCoreTests/
```

## 计时与恢复

- `TimerEngine` 不依赖 SwiftUI。它接收事件并根据绝对截止时间决定下一阶段。AppKit 主线程上的单次定时器只唤起检查。界面的刷新独立计算剩余时间。关闭菜单栏面板后，AppModel 继续调度。
- 标准流程为 `idle → working → breakDue → onBreak → working`。稍后提醒进入 `snoozed` 并在到期后回到 `breakDue`。用户暂停和睡眠暂停都冻结剩余时间，两者分别恢复。当前允许时段结束时关闭会话并清除提醒，下一时段需手动开始。
- 通过 NSWorkspace 捕获睡眠时同步保存暂停快照。唤醒或重新启动时检查允许时段及会话截止时间，再从睡前剩余时间恢复。之前处于待活动的会话在唤醒后只重新提醒一次。
- 正常退出保存快照并撤销待发送通知。在同一允许时段内重新打开时，恢复原截止时间或暂停状态。过期工作只转到一次待活动状态，过期活动只入账一次，并按该轮设置决定是否开始新一轮。恢复时如果会话已经结束，只结算原窗口内已经完成的阶段。
- 如果进程被终止或系统睡前事件未能捕获，只有最后一次已写入的快照可用。应用以其中的绝对截止时间为准，最多结算原有的一个阶段。此时睡眠和退出期间的时间可能计入该阶段。已经进入待活动并保存的会话在重启时保持待活动。
- 每个阶段和每次提醒都有唯一 ID。旧通知操作无法影响新阶段。阶段快照、设置和统计通过同一次原子文件替换写入。重启恢复到「待活动」时，StandUp 会检查系统通知队列，保留与当前阶段匹配的待发送或已送达提醒。两条队列均无匹配提醒时，会按原有重试规则补发。
- 今日统计以系统本地日期分组，保留今天及之前 29 天。累计时长代表完成的活动计时。关闭统计后暂停记录，开启后从新事件继续记录。

## 通知提交与重试

系统通知权限决定 StandUp 能否提交提醒。提交成功表示 macOS 已接受请求，横幅和声音仍由系统通知设置及专注模式控制。

如果系统提交出错，StandUp 等待约 350 毫秒后自动重试一次。重试前会重新检查当前提醒和通知权限。停止计时、切换阶段、暂停、进入睡眠或退出应用都会取消尚未执行的重试。

两次提交失败后，计时器仍处于「待活动」。菜单栏面板会显示「提醒提交失败」，点「重新发送」可对当前提醒再提交一次。也可以直接在面板中选择开始活动、稍后提醒或跳过。

## 已知限制

- 横幅和声音的实际呈现由 macOS 通知设置及专注模式决定。通知权限关闭时仍可在菜单栏处理待活动状态。Soft 音频随包分发，资源缺失时使用默认通知声音。
- 登录启动的注册和批准由 macOS 管理。如果状态显示需要批准，可在「系统设置 → 通用 → 登录项」允许 StandUp。
- 处于允许时段外时，应用停止提交提醒。系统此前已接收的通知由 macOS 管理，StandUp 运行时会在截止时清理其待发送项和已送达项。
- 本机验证范围及尚未实测的系统场景见 [测试报告](TEST-REPORT.md)。

## 卸载

在设置中关闭「登录时自动启动」，然后从菜单栏退出 StandUp。将应用拖入废纸篓。若同时想移除本地设置和历史统计，在 Finder 中打开 `~/Library/Application Support/`，将其中的 `StandUp` 文件夹一并移入废纸篓。应用将快照、设置和统计保存在该目录的 `state.json`。

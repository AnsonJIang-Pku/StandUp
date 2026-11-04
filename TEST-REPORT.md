# StandUp 1.1.2 测试报告

应用版本为 1.1.2，Build 4。2026-11-04 在 Apple Silicon 的 macOS 14.6.1 上验证。工具链为 Xcode 16.2、Swift 6.0.3、macOS SDK 15.2。

## 自动化测试

`swift test` 实际执行 **82 项，82 项通过，0 项失败**。包含 1.1.1 的 68 项测试，以及本次新增的 14 项。通知测试使用可控回调和退避，计时用例使用可控时钟。

| 测试组 | 通过 | 验证内容 |
| --- | ---: | --- |
| NotificationTests | 14 | 延迟成功后的队列清理、跨请求成功或失败回调乱序、提交中及成功后去重、失败可重试、取消保留已送达项、启动清理、通知内容与提示音资源 |
| AppModelNotificationTests | 12 | 保存成功或失败时提交、等待权限时作废、单次自动重试、连续失败和手动重发、停止、暂停、过期或退出取消重试、权限拒绝或撤销、阻止已失效的通知展示和操作 |
| ConfigurationTests | 8 | 参数校验、预设、关闭全局日程时保存草稿 |
| MigrationTests | 4 | 1.0 备份及迁移、默认值、损坏数据及较新版本保护 |
| PersistenceTests | 6 | 会话截止时间、设置、损坏数据、计数去重 |
| SchedulePolicyTests | 9 | 逐日、全天、跨午夜、时区与夏令时 |
| SessionConfigurationTests | 9 | 会话快照、预设、延迟上限、重启、跨午夜及日程即时生效 |
| StatisticsTests | 3 | 指标、本地日期、保留期与去重 |
| TimerEngineTests | 17 | 原有计时、阶段转换、睡眠事件及时间边界 |

## 构建和 GitHub Actions

- Xcode Universal Release 构建成功。包内包含 arm64 和 x86_64，两者最低系统版本均为 macOS 13.0。
- `codesign --verify --deep --strict` 通过，应用为本地 ad-hoc 签名。
- 远端 `main` 基线为 1.1.1 的 `acc82cc09ccdc336043575f6590c5acd66729ea2`，macOS CI 已通过。本报告记录 1.1.2 的本地验证。远端检查记录见 [macOS CI](https://github.com/AnsonJIang-Pku/StandUp/actions/workflows/macos.yml)。[基线 CI 运行](https://github.com/AnsonJIang-Pku/StandUp/actions/runs/41794002841)

## 实机验证边界

竞态测试验证的是模拟通知中心的最终待发送和已送达队列。实际横幅、提示音、锁屏通知、通知中心移除时序和整机睡眠唤醒仍待实机确认。

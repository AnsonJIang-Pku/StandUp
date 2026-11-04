# StandUp 1.1.2 测试报告

应用版本为 1.1.2，Build 4。2026-11-04 在 Apple Silicon 的 macOS 14.6.1 上验证。工具链为 Xcode 16.2、Swift 6.0.3、macOS SDK 15.2。

## 自动化测试

`swift test` 实际执行 **90 项，90 项通过，0 项失败**。包含远端基线的 82 项及新增的 8 项重启恢复测试。两组通知测试共 34 项，额外连续运行三轮均通过。测试使用可控回调、退避和时钟。

| 测试组 | 通过 | 验证内容 |
| --- | ---: | --- |
| NotificationTests | 18 | 保留有效的待发送和已送达提醒，删除过期提醒，隔离启动清理与迟到回调，保留取消语义、去重与失败重试 |
| AppModelNotificationTests | 16 | 缺失提醒只补发一次，恢复提醒可展示并处理三种操作，启动提交等待队列核对，以及原有的保存失败、权限和重试回归 |
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
- 远端 `main` 的 1.1.2 基线 `b0b5766` 已通过 macOS CI。此次重启恢复补丁在本地验证。[基线 CI 运行](https://github.com/AnsonJIang-Pku/StandUp/actions/runs/41814240415)

## 实机验证边界

竞态测试验证的是模拟通知中心的最终待发送和已送达队列，以及应用对恢复通知的展示和操作判断。实际横幅、提示音、锁屏、macOS 通知跨进程交付和整机睡眠唤醒仍待实机确认。

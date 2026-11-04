import SwiftUI
import StandUpCore

struct StatisticsView: View {
    let stats: DailyStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今日活动")
                .font(.headline)
            HStack {
                Text("完成 \(stats.completedActivities) 次")
                Spacer()
                Text("累计 \(stats.activitySeconds / 60) 分钟")
            }
            HStack {
                Text("跳过 \(stats.skips) 次")
                Spacer()
                Text("延迟 \(stats.snoozes) 次")
            }
            Text("工作周期 \(stats.completedWork) 次")
        }
        .font(.callout)
    }
}

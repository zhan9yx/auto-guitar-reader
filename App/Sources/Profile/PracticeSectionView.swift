import SwiftUI
import Charts

/// 练习记录: totals, a 7-day minutes bar chart and per-score history. Reads the shared `PracticeStore`.
struct PracticeSectionView: View {
    let log: PracticeLog
    var now: Date = Date()
    var maxScores = 6

    var body: some View {
        let days = log.dailyMinutes(endingAt: now, days: 7)
        let weekMinutes = days.reduce(0) { $0 + $1.minutes }

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProfileStatCell(value: Self.format(minutes: log.totalMinutes), title: "累计练习")
                ProfileStatCell(value: "\(log.sessionCount)", title: "练习次数")
                ProfileStatCell(value: Self.format(minutes: weekMinutes), title: "近 7 天")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("每日练习分钟（近 7 天）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Chart(days) { day in
                    BarMark(
                        x: .value("日期", day.day, unit: .day),
                        y: .value("分钟", day.minutes)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 110)
                .accessibilityLabel("近 7 天每日练习分钟")
                .accessibilityValue("共 \(Self.format(minutes: weekMinutes)) 分钟")
            }
        }
        .padding(.vertical, 4)

        let perScore = log.perScore()
        if perScore.isEmpty {
            Text("还没有练习记录。在阅读页使用“模拟播放”或“跟弹”后，这里会出现统计。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(perScore.prefix(maxScores)) { item in
                PracticeScoreRow(item: item, now: now)
            }
            if perScore.count > maxScores {
                Text("另有 \(perScore.count - maxScores) 首曲谱的练习记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "0", "12", "1.5 h"-style short minutes label (whole minutes below 100, hours with one decimal above).
    static func format(minutes: Double) -> String {
        if minutes >= 100 { return String(format: "%.1fh", minutes / 60) }
        return String(Int(minutes.rounded()))
    }
}

private struct PracticeScoreRow: View {
    let item: ScorePracticeSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title.isEmpty ? "未命名曲谱" : item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 10) {
                Label("\(Int(item.followMinutes.rounded())) 分钟跟弹", systemImage: "mic")
                Label("\(Int(item.playbackMinutes.rounded())) 分钟播放", systemImage: "play.circle")
                Text("\(item.sessionCount) 次")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("最近练习 " + item.lastPracticed.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI

extension UsageMedal {
    var title: String {
        switch self {
        case .seed: return L10n.tr("种子勋章")
        case .bronze: return L10n.tr("效率新人勋章")
        case .silver: return L10n.tr("效率职人勋章")
        case .gold: return L10n.tr("效率达人勋章")
        }
    }

    var systemImage: String {
        switch self {
        case .seed: return "leaf.fill"
        case .bronze, .silver, .gold: return "medal.fill"
        }
    }

    fileprivate var requirement: String {
        self == .seed ? L10n.tr("首次使用获得") : L10n.tr("使用 %lld 次获得", Int64(threshold))
    }

    fileprivate var tone: Color {
        switch self {
        case .bronze: return Color(red: 0.66, green: 0.35, blue: 0.22)
        case .silver: return Color(red: 0.45, green: 0.48, blue: 0.69)
        case .gold: return Color(red: 0.92, green: 0.49, blue: 0.08)
        case .seed: return Color(red: 0.26, green: 0.50, blue: 0.40)
        }
    }
}

@MainActor
struct UsageSettingsView: View {
    @ObservedObject private var store = PEEKUsageStore.shared
    @AppStorage(PEEKPreferenceKey.showUsageMedal) private var showMedal = true
    @Environment(\.locale) private var locale

    @State private var today = Date()

    var body: some View {
        let snapshot = store.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 16) {
                    HStack {
                        Text(L10n.tr("荣誉勋章")).font(.headline)
                        Spacer()
                        Toggle(L10n.tr("挂载勋章"), isOn: $showMedal)
                            .toggleStyle(.checkbox)
                            .help(L10n.tr("在 PEEK 菜单中展示已获得的最高勋章"))
                    }
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(UsageMedal.allCases, id: \.self) { medal in
                            medalView(medal, count: snapshot.totalCount)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.tr("每日用量")).font(.headline)
                        Spacer()
                        Text(L10n.tr("最近 22 周")).font(.caption).foregroundStyle(.secondary)
                    }
                    UsageHeatmap(snapshot: snapshot, today: today)
                }

                Label {
                    Text(summary(snapshot, asOf: today))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "chart.bar.fill").foregroundStyle(Color.accentColor)
                }
                .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .onAppear { today = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in today = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in today = Date() }
    }

    private func medalView(_ medal: UsageMedal, count: Int) -> some View {
        let earned = count >= medal.threshold
        let status = earned ? L10n.tr("已获得") : L10n.tr("未获得")
        return VStack(spacing: 5) {
            UsageMedalArtwork(medal: medal, earned: earned)
                .accessibilityHidden(true)
            Text(medal.title)
                .font(.body.weight(.semibold))
            HStack(spacing: 4) {
                Image(systemName: earned ? "checkmark.circle.fill" : "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(earned ? Color.green : Color.secondary)
                Text(medal.requirement)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(medal.title))
        .accessibilityValue(Text("\(status) · \(medal.requirement)"))
        .help("\(status) · \(medal.requirement)")
    }

    private func summary(_ snapshot: PEEKUsageSnapshot, asOf date: Date) -> String {
        guard let start = snapshot.firstUseDate else {
            return L10n.tr("首次完成操作后，这里会显示累计次数和日均用量。")
        }
        let startDate = start.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(locale))
        let total = snapshot.totalCount.formatted(.number.locale(locale))
        let average = snapshot.dailyAverage(asOf: date)
            .formatted(.number.precision(.fractionLength(1)).locale(locale))
        return L10n.tr("自 %@ 起，PEEK 已为你完成 %@ 次操作，平均每天 %@ 次。", startDate, total, average)
    }
}

private struct UsageMedalArtwork: View {
    let medal: UsageMedal
    let earned: Bool

    var body: some View {
        ZStack {
            Canvas { context, size in
                // All paths share a 100 × 80 coordinate system, including the bevels.
                context.scaleBy(x: size.width / 100, y: size.height / 80)
                let tone = medal.tone
                let metal = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [.white.opacity(0.92), tone, tone.opacity(0.83), .white.opacity(0.8)]),
                    startPoint: CGPoint(x: 32, y: 4), endPoint: CGPoint(x: 69, y: 75)
                )
                if medal != .seed {
                    var wings = Path()
                    for mirrored in [false, true] {
                        for row in 0..<3 {
                            let y = CGFloat(18 + row * 9)
                            let x = CGFloat(4 + row * 4)
                            let points = [
                                CGPoint(x: x, y: y), CGPoint(x: 32, y: y + 8),
                                CGPoint(x: 32, y: y + 16), CGPoint(x: x, y: y + 7)
                            ].map { CGPoint(x: mirrored ? 100 - $0.x : $0.x, y: $0.y) }
                            wings.addLines(points)
                            wings.closeSubpath()
                        }
                    }
                    context.fill(wings, with: metal)
                    context.stroke(wings, with: .color(tone.opacity(0.8)), lineWidth: 1)
                }
                let outer = shield(inset: 0)
                context.fill(outer, with: metal)
                context.stroke(outer, with: .color(tone), lineWidth: 1.5)
                let inner = shield(inset: 4)
                context.fill(inner, with: .linearGradient(
                    Gradient(colors: [tone, tone.opacity(0.83), tone]),
                    startPoint: CGPoint(x: 50, y: 9), endPoint: CGPoint(x: 50, y: 72)
                ))
                context.stroke(inner, with: .color(.white.opacity(0.66)), lineWidth: 1.5)
            }

            if medal == .seed {
                Image(systemName: medal.systemImage)
                    .font(.system(size: 23, weight: .medium))
            } else {
                Text(verbatim: medal == .gold ? "3K" : String(medal.threshold))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 100, height: 80)
        .saturation(earned ? 1 : 0.34)
        .opacity(earned ? 1 : 0.78)
        .shadow(color: .black.opacity(earned ? 0.22 : 0.12), radius: 2, y: 1)
    }

    private func shield(inset: CGFloat) -> Path {
        let vertices = [
            CGPoint(x: 50, y: 4), CGPoint(x: 78, y: 20), CGPoint(x: 78, y: 57),
            CGPoint(x: 50, y: 75), CGPoint(x: 22, y: 57), CGPoint(x: 22, y: 20)
        ].map { CGPoint(x: 50 + ($0.x - 50) * (1 - inset / 28),
                        y: 40 + ($0.y - 40) * (1 - inset / 35)) }
        func near(_ vertex: CGPoint, towards other: CGPoint) -> CGPoint {
            CGPoint(x: vertex.x + (other.x - vertex.x) * 0.09,
                    y: vertex.y + (other.y - vertex.y) * 0.09)
        }
        var path = Path()
        for index in vertices.indices {
            let vertex = vertices[index]
            let before = near(vertex, towards: vertices[(index + 5) % 6])
            let after = near(vertex, towards: vertices[(index + 1) % 6])
            if index == 0 { path.move(to: before) } else { path.addLine(to: before) }
            path.addQuadCurve(to: after, control: vertex)
        }
        path.closeSubpath()
        return path
    }
}

private struct UsageHeatmap: View {
    let snapshot: PEEKUsageSnapshot
    let today: Date
    @Environment(\.locale) private var locale

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        value.firstWeekday = 2
        return value
    }

    var body: some View {
        let calendar = calendar
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? calendar.startOfDay(for: today)
        let weeks = (-21...0).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: currentWeek) }
        VStack(alignment: .trailing, spacing: 8) {
            GeometryReader { proxy in
                let columnWidth = proxy.size.width / CGFloat(weeks.count)
                let cellSize = max(4, min(24, columnWidth - 7))
                HStack(alignment: .top, spacing: 0) {
                    ForEach(weeks, id: \.self) { week in
                        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
                        VStack(spacing: 4) {
                            let month = week == weeks.first ? days.first : days.first {
                                $0 <= today && calendar.component(.day, from: $0) == 1
                            }
                            Text(month.map { $0.formatted(.dateTime.month(.abbreviated).locale(locale)) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize().frame(width: columnWidth, height: 18)
                                .accessibilityHidden(true)
                            VStack(spacing: 5) {
                                ForEach(days, id: \.self) { day in
                                    dayCell(day, size: cellSize)
                                }
                            }
                            .padding(3)
                            .overlay {
                                if week == currentWeek {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .frame(width: columnWidth)
                    }
                }
            }
            .frame(height: 226)
            HStack(spacing: 4) {
                Text(L10n.tr("少"))
                ForEach([0, 1, 3, 6, 10], id: \.self) { value in
                    RoundedRectangle(cornerRadius: 3).fill(color(for: value)).frame(width: 12, height: 12)
                }
                Text(L10n.tr("多"))
            }
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L10n.tr("颜色越深表示当天使用次数越多")))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    private func dayCell(_ date: Date, size: CGFloat) -> some View {
        let count = snapshot.count(on: date)
        let dateLabel = date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(locale))
        let label = L10n.tr("%@，使用 %lld 次", dateLabel, Int64(count))
        let future = date > today
        return RoundedRectangle(cornerRadius: 4)
            .fill(future ? Color.clear : color(for: count))
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityHidden(future)
            .help(future ? "" : label)
    }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: return Color.primary.opacity(0.10)
        case 1...2: return Color(red: 0.75, green: 0.87, blue: 1)
        case 3...5: return Color(red: 0.50, green: 0.74, blue: 1)
        case 6...9: return Color(red: 0.23, green: 0.60, blue: 0.98)
        default: return Color(red: 0.03, green: 0.44, blue: 0.85)
        }
    }
}

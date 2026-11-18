import Combine
import Foundation

enum UsageMedal: String, CaseIterable, Identifiable {
    case bronze, silver, gold, seed

    var id: Self { self }

    var threshold: Int {
        switch self {
        case .seed: return 1
        case .bronze: return 50
        case .silver: return 300
        case .gold: return 3_000
        }
    }

    static func highestEarned(in snapshot: PEEKUsageSnapshot) -> Self? {
        let count = snapshot.totalCount
        return allCases.filter { $0.threshold <= count }.max { $0.threshold < $1.threshold }
    }
}

struct PEEKUsageSnapshot {
    private static let utcDayFormat = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()

    fileprivate private(set) var dailyCounts: [String: Int]
    private let timeZone: TimeZone

    fileprivate init(dailyCounts: [String: Int], timeZone: TimeZone) {
        self.timeZone = timeZone
        let format = Self.utcDayFormat
        self.dailyCounts = dailyCounts.filter { day, count in
            guard count > 0, let date = try? format.parse(day) else { return false }
            return format.format(date) == day
        }
    }

    // A local calendar date retains its original label when the user travels.
    private var dayFormat: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
    }

    var totalCount: Int {
        dailyCounts.values.reduce(0) { total, count in
            total + min(count, Int.max - total)
        }
    }

    var firstUseDate: Date? {
        dailyCounts.keys.min().flatMap { try? dayFormat.parse($0) }
    }

    func count(on date: Date) -> Int {
        dailyCounts[dayFormat.format(date), default: 0]
    }

    /// The overview includes every recorded use, even when travelling west
    /// makes a previously observed local date later than today's date.
    func lifetimeSummary(on date: Date) -> (startDayUTC: Date, average: Double)? {
        let lastDay = dayFormat.format(date)
        guard let firstDay = dailyCounts.keys.min(),
              let span = calendarDaySpan(from: min(firstDay, lastDay), through: lastDay) else { return nil }
        return (span.startDayUTC, Double(totalCount) / span.days)
    }

    func dailyAverage(asOf date: Date) -> Double {
        let lastDay = dayFormat.format(date)
        guard let firstDay = dailyCounts.keys.min(), firstDay <= lastDay,
              let span = calendarDaySpan(from: firstDay, through: lastDay) else { return 0 }
        let uses = dailyCounts.reduce(0.0) { total, entry in
            entry.key <= lastDay ? total + Double(entry.value) : total
        }
        return uses / span.days
    }

    private func calendarDaySpan(from first: String, through last: String) -> (startDayUTC: Date, days: Double)? {
        // A stored date may never have existed in the viewer's current zone.
        // Use UTC for both counting and displaying these calendar labels.
        guard let start = try? Self.utcDayFormat.parse(first),
              let end = try? Self.utcDayFormat.parse(last) else { return nil }
        return (start, end.timeIntervalSince(start) / 86_400 + 1)
    }

    fileprivate mutating func recordUse(at date: Date) {
        let key = dayFormat.format(date)
        if dailyCounts[key, default: 0] < Int.max {
            dailyCounts[key, default: 0] += 1
        }
    }
}

/// Only daily event counts are retained. The underlying action carries no payload.
@MainActor
final class PEEKUsageStore: ObservableObject {
    static let shared = PEEKUsageStore()

    private static let storageKey = "usage.dailyCounts.v1"
    private let defaults: UserDefaults
    @Published private(set) var snapshot: PEEKUsageSnapshot

    init(defaults: UserDefaults = .standard, timeZone: TimeZone = .autoupdatingCurrent) {
        self.defaults = defaults
        let values = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        snapshot = PEEKUsageSnapshot(dailyCounts: values.compactMapValues { $0 as? Int }, timeZone: timeZone)
    }

    func recordUse(at date: Date = Date()) {
        snapshot.recordUse(at: date)
        defaults.set(snapshot.dailyCounts, forKey: Self.storageKey)
    }
}

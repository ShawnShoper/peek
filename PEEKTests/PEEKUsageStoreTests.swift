import XCTest
@testable import PEEK

final class PEEKUsageStoreTests: XCTestCase {
    @MainActor
    func testLocalCalendarDaysIncludeInactiveDaysAndSurviveRestart() throws {
        let suiteName = "PEEKTests.Usage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let store = PEEKUsageStore(defaults: defaults, timeZone: zone)
        let iso = ISO8601DateFormatter()
        // The US spring transition makes the local day of March 10 only 23 hours long.
        let first = try XCTUnwrap(iso.date(from: "2024-03-10T07:59:00Z")) // March 9, 23:59
        let nextDay = try XCTUnwrap(iso.date(from: "2024-03-10T08:01:00Z"))
        let thirdDay = try XCTUnwrap(iso.date(from: "2024-03-11T07:00:00Z"))
        XCTAssertNil(store.snapshot.firstUseDate)
        XCTAssertEqual(store.snapshot.dailyAverage(asOf: first), 0)

        store.recordUse(at: first)
        store.recordUse(at: first)
        store.recordUse(at: thirdDay)
        let restored = PEEKUsageStore(defaults: defaults, timeZone: zone).snapshot
        XCTAssertEqual(restored.totalCount, 3)
        XCTAssertEqual(restored.count(on: first), 2)
        XCTAssertEqual(restored.count(on: nextDay), 0)
        XCTAssertEqual(restored.count(on: thirdDay), 1)
        XCTAssertEqual(restored.firstUseDate, iso.date(from: "2024-03-09T08:00:00Z"))
        XCTAssertEqual(restored.dailyAverage(asOf: thirdDay), 1)
        XCTAssertEqual(restored.dailyAverage(asOf: first), 2)
    }

    @MainActor
    func testDailyAverageIncludesDatesWhoseLocalMidnightWasSkipped() throws {
        let suiteName = "PEEKTests.Usage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let zone = try XCTUnwrap(TimeZone(identifier: "Africa/Cairo"))
        let store = PEEKUsageStore(defaults: defaults, timeZone: zone)
        let iso = ISO8601DateFormatter()
        // Cairo skipped 00:00–00:59 on April 26. April 27 still counts as day two.
        store.recordUse(at: try XCTUnwrap(iso.date(from: "2024-04-25T22:00:00Z")))
        let nextMidnight = try XCTUnwrap(iso.date(from: "2024-04-26T21:00:00Z"))
        XCTAssertEqual(store.snapshot.dailyAverage(asOf: nextMidnight), 0.5)
    }

    @MainActor
    func testMedalChangesOnlyWhenItsThresholdIsReached() throws {
        let suiteName = "PEEKTests.Usage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 0)
        let milestones: [(Int, UsageMedal?, UsageMedal)] = [
            (1, nil, .seed), (50, .seed, .bronze), (300, .bronze, .silver), (3_000, .silver, .gold)
        ]
        for (threshold, previous, expected) in milestones {
            defaults.set(["1970-01-01": threshold - 1], forKey: "usage.dailyCounts.v1")
            let store = PEEKUsageStore(defaults: defaults, timeZone: zone)
            XCTAssertEqual(UsageMedal.highestEarned(in: store.snapshot), previous)
            store.recordUse(at: date)
            XCTAssertEqual(UsageMedal.highestEarned(in: store.snapshot), expected)
        }
    }

    @MainActor
    func testHeatmapPreservesBothMonthsWhenFirstWeekSpansJuneAndJuly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2
        let firstWeek = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 29)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23)))
        let weeks = try (0..<22).map { offset in
            try XCTUnwrap(calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeek))
        }
        XCTAssertEqual(weeks.last, today)

        let labels = UsageHeatmap.monthLabels(for: weeks, through: today, calendar: calendar)
        let monthsByWeek = labels.mapValues { calendar.component(.month, from: $0) }

        XCTAssertEqual(monthsByWeek[weeks[0]], 6)
        XCTAssertEqual(monthsByWeek[weeks[1]], 7)
        XCTAssertEqual(weeks.compactMap { monthsByWeek[$0] }, [6, 7, 8, 9, 10, 11])
    }

    @MainActor
    func testHeatmapShowsJanuaryInCurrentWeekOnlyAfterNewYearStarts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2
        let firstWeek = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 21)))
        let currentWeek = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 28)))
        let weeks = [firstWeek, currentWeek]
        let newYearsEve = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31)))
        let newYearsDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))

        let before = UsageHeatmap.monthLabels(for: weeks, through: newYearsEve, calendar: calendar)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(before[firstWeek])), 12)
        XCTAssertNil(before[currentWeek])

        let after = UsageHeatmap.monthLabels(for: weeks, through: newYearsDay, calendar: calendar)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[firstWeek], before[firstWeek])
        let january = try XCTUnwrap(after[currentWeek])
        XCTAssertEqual(calendar.component(.year, from: january), 2027)
        XCTAssertEqual(calendar.component(.month, from: january), 1)
    }
}

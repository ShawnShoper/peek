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
}

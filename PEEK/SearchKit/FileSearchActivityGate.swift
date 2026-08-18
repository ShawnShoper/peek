import CoreGraphics
import Foundation

enum FileSearchActivityBlocker: String, Hashable, Sendable {
    case searchPanel
    case capture
    case ocr
    case fileOperation
    case userActive
    case lowPower
    case thermalPressure
    case systemDeferral
}

struct FileSearchActivityGateSnapshot: Equatable, Sendable {
    let blockers: Set<FileSearchActivityBlocker>

    var canIndex: Bool { blockers.isEmpty }
}

/// Central pause switch for user-facing work. Callers only set explicit app
/// activities; power, thermal and keyboard/mouse idleness are sampled here.
actor FileSearchActivityGate {
    static let shared = FileSearchActivityGate()

    private var explicitBlockers: Set<FileSearchActivityBlocker> = []
    private var requiredIdleDuration: TimeInterval

    init(requiredIdleDuration: TimeInterval = 30) {
        self.requiredIdleDuration = max(0, requiredIdleDuration)
    }

    func setRequiredIdleDuration(_ duration: TimeInterval) {
        requiredIdleDuration = max(0, duration)
    }

    func setActivity(
        _ isActive: Bool,
        blocker: FileSearchActivityBlocker
    ) {
        if isActive {
            explicitBlockers.insert(blocker)
        } else {
            explicitBlockers.remove(blocker)
        }
    }

    func snapshot(
        ignoring ignoredBlockers: Set<FileSearchActivityBlocker> = []
    ) -> FileSearchActivityGateSnapshot {
        var blockers = explicitBlockers
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled {
            blockers.insert(.lowPower)
        }
        switch processInfo.thermalState {
        case .serious, .critical:
            blockers.insert(.thermalPressure)
        case .nominal, .fair:
            break
        @unknown default:
            blockers.insert(.thermalPressure)
        }

        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        if secondsSinceInput.isFinite,
           secondsSinceInput < requiredIdleDuration {
            blockers.insert(.userActive)
        }
        blockers.subtract(ignoredBlockers)
        return FileSearchActivityGateSnapshot(blockers: blockers)
    }

    /// Sleeps without busy polling while an interactive activity is active.
    /// A bounded wait lets NSBackgroundActivityScheduler defer long sessions.
    func waitUntilAllowed(
        maximumWait: TimeInterval,
        ignoring ignoredBlockers: Set<FileSearchActivityBlocker> = []
    ) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, maximumWait)
        while !snapshot(ignoring: ignoredBlockers).canIndex {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return false
            }
            try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
        }
        return true
    }
}

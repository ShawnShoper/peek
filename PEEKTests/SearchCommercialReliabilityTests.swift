import Foundation
import Dispatch
import XCTest
@testable import PEEK

final class SearchCommercialReliabilityTests: XCTestCase {
    func testCopyPublishesCompleteDestinationWithoutStagingResidue() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("complete payload".utf8).write(to: source)

        let outcome = try await DefaultSearchPanelActionHandler.runFileOperation(
            source: source,
            destination: destination,
            shouldMove: false
        )

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(try String(contentsOf: destination), "complete payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(try directoryContainsStagingItem(root))
    }

    func testMovePublishesDestinationAndRemovesSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("move payload".utf8).write(to: source)

        let outcome = try await DefaultSearchPanelActionHandler.runFileOperation(
            source: source,
            destination: destination,
            shouldMove: true
        )

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(try String(contentsOf: destination), "move payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(try directoryContainsStagingItem(root))
    }

    func testExistingDestinationIsNeverOverwritten() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("new".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)

        do {
            try await DefaultSearchPanelActionHandler.runFileOperation(
                source: source,
                destination: destination,
                shouldMove: false
            )
            XCTFail("Expected destinationExists")
        } catch SearchPanelActionError.destinationExists {
            // Expected.
        }

        XCTAssertEqual(try String(contentsOf: destination), "existing")
        XCTAssertFalse(try directoryContainsStagingItem(root))
    }

    func testCancelledMoveKeepsSourceVisibleAndRemovesUnpublishedStagingCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("source remains safe".utf8).write(to: source)

        let reachedStagingCopy = DispatchSemaphore(value: 0)
        let resumeWorker = DispatchSemaphore(value: 0)
        let operation = Task {
            try await DefaultSearchPanelActionHandler.runFileOperation(
                source: source,
                destination: destination,
                shouldMove: true,
                hooks: .init(
                    afterStagingCopy: {
                        reachedStagingCopy.signal()
                        resumeWorker.wait()
                    },
                    sameVolumeOverride: false
                )
            )
        }

        XCTAssertEqual(reachedStagingCopy.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try directoryContainsStagingItem(root))
        operation.cancel()
        resumeWorker.signal()

        do {
            try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try String(contentsOf: source), "source remains safe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try directoryContainsStagingItem(root))
    }

    func testCrossVolumeMovePreservesSourceIfItChangesDuringCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("original".utf8).write(to: source)

        let outcome = try await DefaultSearchPanelActionHandler.runFileOperation(
            source: source,
            destination: destination,
            shouldMove: true,
            hooks: .init(
                afterStagingCopy: {
                    try? Data("replacement".utf8).write(to: source, options: .atomic)
                },
                sameVolumeOverride: false
            )
        )

        XCTAssertEqual(outcome, .copiedAcrossVolumes)
        XCTAssertEqual(try String(contentsOf: source), "replacement")
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertFalse(try directoryContainsStagingItem(root))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PEEK-SearchCommercialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func directoryContainsStagingItem(_ root: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).contains {
            $0.lastPathComponent.hasPrefix("PEEK-")
                && $0.lastPathComponent.hasSuffix(".partial")
        }
    }
}

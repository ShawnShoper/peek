import XCTest
@testable import PEEK

final class OnboardingGuideTests: XCTestCase {
    func testFreshInstallQueuesGuideExactlyOnceWithoutCompletingIt() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            PEEKFirstLaunchOnboardingPolicy.shouldAutomaticallyPresent(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            PEEKFirstLaunchOnboardingPolicy.preparePresentationIfNeeded(
                defaults: defaults
            )
        )
        XCTAssertTrue(defaults.bool(forKey: PEEKPreferenceKey.didAutoPresentOnboarding))
        XCTAssertTrue(defaults.bool(forKey: PEEKPreferenceKey.openOnboarding))
        XCTAssertNil(defaults.object(
            forKey: PEEKPreferenceKey.didPresentDocumentAuthorization
        ))
        XCTAssertFalse(defaults.bool(forKey: PEEKPreferenceKey.didCompleteOnboarding))

        XCTAssertTrue(
            PEEKFirstLaunchOnboardingPolicy.consumePendingPresentation(
                defaults: defaults
            )
        )
        XCTAssertFalse(
            PEEKFirstLaunchOnboardingPolicy.consumePendingPresentation(
                defaults: defaults
            )
        )
        XCTAssertFalse(
            PEEKFirstLaunchOnboardingPolicy.preparePresentationIfNeeded(
                defaults: defaults
            )
        )
    }

    func testExistingInstallIsMigratedWithoutAutomaticGuide() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Presence of this legacy first-launch marker identifies an upgrade.
        defaults.set(true, forKey: PEEKPreferenceKey.didPresentDocumentAuthorization)

        XCTAssertFalse(
            PEEKFirstLaunchOnboardingPolicy.preparePresentationIfNeeded(
                defaults: defaults
            )
        )
        XCTAssertTrue(defaults.bool(forKey: PEEKPreferenceKey.didAutoPresentOnboarding))
        XCTAssertFalse(defaults.bool(forKey: PEEKPreferenceKey.openOnboarding))
        XCTAssertFalse(defaults.bool(forKey: PEEKPreferenceKey.didCompleteOnboarding))
    }

    func testFinishingOrSkippingCompletesGuideAndClearsPendingRoute() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PEEKFirstLaunchOnboardingPolicy.requestReplay(defaults: defaults)
        PEEKFirstLaunchOnboardingPolicy.markCompleted(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: PEEKPreferenceKey.didCompleteOnboarding))
        XCTAssertTrue(defaults.bool(forKey: PEEKPreferenceKey.didAutoPresentOnboarding))
        XCTAssertFalse(defaults.bool(forKey: PEEKPreferenceKey.openOnboarding))
        XCTAssertFalse(
            PEEKFirstLaunchOnboardingPolicy.shouldAutomaticallyPresent(
                defaults: defaults
            )
        )
    }

    func testReplayDoesNotClearCompletionOrReenableAutomaticPresentation() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PEEKFirstLaunchOnboardingPolicy.markCompleted(defaults: defaults)
        PEEKFirstLaunchOnboardingPolicy.requestReplay(defaults: defaults)

        XCTAssertTrue(
            PEEKFirstLaunchOnboardingPolicy.consumePendingPresentation(
                defaults: defaults
            )
        )
        XCTAssertTrue(defaults.bool(forKey: PEEKPreferenceKey.didCompleteOnboarding))
        XCTAssertFalse(
            PEEKFirstLaunchOnboardingPolicy.shouldAutomaticallyPresent(
                defaults: defaults
            )
        )
    }

    func testGuideStepsCoverEverySettingsFeatureGroupInStableOrder() {
        let steps = OnboardingGuideStep.allCases

        XCTAssertEqual(steps.count, 11)
        XCTAssertEqual(steps.first, .welcome)
        XCTAssertEqual(steps.last, .complete)
        XCTAssertEqual(Set(steps.map(\.id)).count, steps.count)
        XCTAssertEqual(Set(steps.map(\.target)).count, steps.count)
        XCTAssertEqual(
            Set(steps.map(\.destination.rawValue)),
            Set([
                "general",
                "search",
                "clipboard",
                "shortcuts",
                "translation",
                "capture",
                "appearance",
                "about",
            ])
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "PEEK-Onboarding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

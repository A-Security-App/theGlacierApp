import XCTest
@testable import Glacier

@MainActor
final class DiscoverySurveyTests: XCTestCase {

    private static let forceSurveyKey = "GlacierForceDiscoverySurvey"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.forceSurveyKey)
        UserDefaultsService.shared.remove(for: \.isUserOnboardingCompleted)
        UserDefaultsService.shared.remove(for: \.didSkipPhoneNumberPurchaseDuringOnboarding)
        UserDefaultsService.shared.remove(for: \.inProgressUserOnboardingScreen)
        DiscoverySurveyService.shared.reset()
        super.tearDown()
    }

    // MARK: - Answer

    func testChannelIDsMatchTheSharedContract() {
        XCTAssertEqual(DiscoveryChannel.allCases.map(\.rawValue), [
            "web_search", "podcast", "youtube", "social_media", "publication",
            "word_of_mouth", "ai_assistant", "app_store", "other", "dont_remember",
        ])
    }

    func testFriendOrFamilyNeverAsksForDetail() {
        XCTAssertNil(DiscoveryChannel.wordOfMouth.detailPrompt)
    }

    func testDetailIsTrimmedAndBlankDetailIsDropped() {
        XCTAssertEqual(DiscoverySurveyAnswer(channel: .podcast, detail: "  Darknet Diaries \n").detail, "Darknet Diaries")
        XCTAssertNil(DiscoverySurveyAnswer(channel: .podcast, detail: "   ").detail)
        XCTAssertNil(DiscoverySurveyAnswer(channel: .podcast, detail: nil).detail)
    }

    func testControlCharactersInDetailBecomeSpaces() {
        XCTAssertEqual(DiscoverySurveyAnswer(channel: .podcast, detail: "Darknet\tDiaries\u{7}").detail, "Darknet Diaries")
    }

    func testDetailIsDroppedForChannelsThatDontAskForIt() {
        XCTAssertNil(DiscoverySurveyAnswer(channel: .webSearch, detail: "glacier vpn").detail)
    }

    func testDetailIsCappedAtTheBackendLimitInCodePoints() {
        let long = String(repeating: "é", count: 200)
        let detail = DiscoverySurveyAnswer(channel: .other, detail: long).detail
        XCTAssertEqual(detail?.unicodeScalars.count, DiscoverySurveyAnswer.maxDetailLength)
    }

    // MARK: - View model

    func testChangingChannelClearsDetail() {
        let viewModel = DiscoverySurveyVM(rootCoordinator: GlacierAppRootCoordinator(), completionFlag: \.isUserOnboardingCompleted)
        viewModel.select(.podcast)
        viewModel.detail = "Some podcast"
        viewModel.select(.podcast)
        XCTAssertEqual(viewModel.detail, "Some podcast")
        viewModel.select(.youtube)
        XCTAssertEqual(viewModel.detail, "")
    }

    func testSkipFinishesOnboardingWithTheGivenFlag() {
        let rootCoordinator = GlacierAppRootCoordinator()
        let viewModel = DiscoverySurveyVM(rootCoordinator: rootCoordinator, completionFlag: \.didSkipPhoneNumberPurchaseDuringOnboarding)
        viewModel.skip()
        XCTAssertEqual(rootCoordinator.currentScreen, .main)
        XCTAssertEqual(UserDefaultsService.shared.get(for: \.didSkipPhoneNumberPurchaseDuringOnboarding), true)
        XCTAssertNotEqual(UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted), true)
    }

    func testSubmitNeedsAChannel() {
        let rootCoordinator = GlacierAppRootCoordinator()
        rootCoordinator.setScreen(.userOnboarding)
        let viewModel = DiscoverySurveyVM(rootCoordinator: rootCoordinator, completionFlag: \.isUserOnboardingCompleted)
        viewModel.submit()
        XCTAssertEqual(rootCoordinator.currentScreen, .userOnboarding)
        viewModel.select(.aiAssistant)
        viewModel.submit()
        XCTAssertEqual(rootCoordinator.currentScreen, .main)
    }

    // MARK: - Routing

    func testOnboardingGoesStraightToMainWhenStatusIsUnknown() {
        let rootCoordinator = GlacierAppRootCoordinator()
        rootCoordinator.setScreen(.userOnboarding)
        let onboardingCoordinator = UserOnboardingCoordinator(rootCoordinator: rootCoordinator, startingAt: .dnsSetup)
        let viewModel = DiscoverySurveyVM(rootCoordinator: rootCoordinator, completionFlag: \.isUserOnboardingCompleted)

        viewModel.finishOnboarding()

        XCTAssertEqual(rootCoordinator.currentScreen, .main)
        XCTAssertNotEqual(onboardingCoordinator.currentScreen, .discoverySurvey)
    }

    func testOnboardingEndsOnTheSurveyWhenTheAccountShouldBeAsked() {
        UserDefaults.standard.set(true, forKey: Self.forceSurveyKey)
        let rootCoordinator = GlacierAppRootCoordinator()
        rootCoordinator.setScreen(.userOnboarding)
        let onboardingCoordinator = UserOnboardingCoordinator(rootCoordinator: rootCoordinator, startingAt: .dnsSetup)
        let viewModel = DiscoverySurveyVM(rootCoordinator: rootCoordinator, completionFlag: \.isUserOnboardingCompleted)

        viewModel.finishOnboarding(marking: \.didSkipPhoneNumberPurchaseDuringOnboarding)

        XCTAssertEqual(onboardingCoordinator.currentScreen, .discoverySurvey)
        XCTAssertEqual(rootCoordinator.currentScreen, .userOnboarding)
        XCTAssertNotEqual(UserDefaultsService.shared.get(for: \.didSkipPhoneNumberPurchaseDuringOnboarding), true)
    }

    func testSurveyIsNotShownOutsideOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.forceSurveyKey)
        let rootCoordinator = GlacierAppRootCoordinator()
        let onboardingCoordinator = UserOnboardingCoordinator(rootCoordinator: rootCoordinator, startingAt: .dnsSetup)
        rootCoordinator.setScreen(.main)
        let viewModel = DiscoverySurveyVM(rootCoordinator: rootCoordinator, completionFlag: \.isUserOnboardingCompleted)

        viewModel.finishOnboarding()

        XCTAssertNotEqual(onboardingCoordinator.currentScreen, .discoverySurvey)
        XCTAssertEqual(UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted), true)
    }
}

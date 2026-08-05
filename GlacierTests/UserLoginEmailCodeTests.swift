import XCTest
import Amplify
import AWSCognitoAuthPlugin
import SwiftUI
@testable import Glacier

/// Covers the email-code challenge on the login path: that login asks for it,
/// that a challenge parks the view model on the code screen, and that a code
/// Cognito rejects sends the user back to the start.
///
/// The success path is deliberately not exercised here. It runs
/// `AWSAcctManager.fetchAttributes()` and the app delegate's subscription
/// resolve, both of which talk to live services.
@MainActor
final class UserLoginEmailCodeTests: XCTestCase {

    // MARK: - Flow mapping

    func testEmailCodeChallengeMapsToCustomWithSRP() {
        // USER_SRP_AUTH never reaches the pool's challenge triggers, so this
        // mapping is the whole reason the app receives a code at all.
        guard case .customWithSRP = GlacierSignInFlow.emailCodeChallenge.authFlowType else {
            return XCTFail("emailCodeChallenge must request CUSTOM_WITH_SRP")
        }
        guard case .userSRP = GlacierSignInFlow.passwordOnly.authFlowType else {
            return XCTFail("passwordOnly must request USER_SRP_AUTH")
        }
    }

    // MARK: - Fallback detection

    /// The exact error Cognito returns when the app client has no
    /// `ALLOW_CUSTOM_AUTH`. An earlier matcher looked for "auth flow", which this
    /// message does not contain, so the SRP fallback never fired and sign-in
    /// failed closed instead of degrading. This pins the real message.
    func testCustomAuthUnavailableMatchesTheRealCognitoMessage() {
        let error = AuthError.service(
            "CUSTOM_AUTH is not enabled for the client",
            "Make sure that the parameters passed are valid",
            AWSCognitoAuthError.invalidParameter
        )
        XCTAssertTrue(AmplifyAuthenticationService.isCustomAuthUnavailable(error))
    }

    /// An unrelated `.invalidParameter` must NOT be treated as "custom auth off",
    /// or a genuine bad request would be silently downgraded to a codeless login.
    func testUnrelatedInvalidParameterIsNotTreatedAsCustomAuthUnavailable() {
        let error = AuthError.service(
            "2 validation errors detected: value at 'password' failed to satisfy constraint",
            "Make sure that the parameters passed are valid",
            AWSCognitoAuthError.invalidParameter
        )
        XCTAssertFalse(AmplifyAuthenticationService.isCustomAuthUnavailable(error))
    }

    /// A different Cognito error class must not trigger the fallback either.
    func testNonInvalidParameterErrorIsNotTreatedAsCustomAuthUnavailable() {
        let error = AuthError.notAuthorized(
            "Incorrect username or password",
            "Check whether the given values are correct",
            AWSCognitoAuthError.userNotFound
        )
        XCTAssertFalse(AmplifyAuthenticationService.isCustomAuthUnavailable(error))
    }

    // MARK: - Login

    func testLoginRequestsTheEmailCodeFlow() async {
        let service = MockAuthenticationService()
        service.signInResult = AuthSignInResult(nextStep: .confirmSignInWithCustomChallenge(nil))
        let viewModel = makeViewModel(service: service)
        viewModel.email = "person@example.com"
        viewModel.password = "hunter2hunter2"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.isAwaitingVerificationCode }

        XCTAssertEqual(service.requestedFlows, [.emailCodeChallenge])
    }

    func testCustomChallengeParksOnCodeEntryWithTheMaskedDestination() async {
        let service = MockAuthenticationService()
        service.signInResult = AuthSignInResult(
            nextStep: .confirmSignInWithCustomChallenge(["destination": "p***n@example.com"])
        )
        let viewModel = makeViewModel(service: service)
        viewModel.email = "person@example.com"
        viewModel.password = "hunter2hunter2"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.isAwaitingVerificationCode }

        XCTAssertEqual(viewModel.verificationCodeDestination, "p***n@example.com")
    }

    func testCustomChallengeWithoutADestinationStillOpensCodeEntry() async {
        let service = MockAuthenticationService()
        service.signInResult = AuthSignInResult(nextStep: .confirmSignInWithCustomChallenge(nil))
        let viewModel = makeViewModel(service: service)
        viewModel.email = "person@example.com"
        viewModel.password = "hunter2hunter2"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.isAwaitingVerificationCode }

        XCTAssertNil(viewModel.verificationCodeDestination)
    }

    // MARK: - Answering the code

    func testRejectedCodeSendsTheUserBackToSignIn() async {
        let service = MockAuthenticationService()
        // Cognito ends the session on a wrong code and reports the challenge
        // again rather than signing the user in.
        service.confirmSignInResult = AuthSignInResult(
            nextStep: .confirmSignInWithCustomChallenge(nil)
        )
        let viewModel = makeViewModel(service: service)
        viewModel.isAwaitingVerificationCode = true
        viewModel.verificationCodeDestination = "p***n@example.com"
        viewModel.password = "hunter2hunter2"

        viewModel.submitVerificationCode("000000")
        await waitUntil { !viewModel.isAwaitingVerificationCode }

        XCTAssertEqual(service.submittedCodes, ["000000"])
        XCTAssertNil(viewModel.verificationCodeDestination)
        // The next attempt opens a new Cognito session, so the old password is
        // of no further use and must not sit in memory.
        XCTAssertEqual(viewModel.password, "")
    }

    func testCancellingCodeEntryClearsTheChallenge() {
        let viewModel = makeViewModel(service: MockAuthenticationService())
        viewModel.isAwaitingVerificationCode = true
        viewModel.verificationCodeDestination = "p***n@example.com"
        viewModel.password = "hunter2hunter2"

        viewModel.cancelVerificationCodeEntry()

        XCTAssertFalse(viewModel.isAwaitingVerificationCode)
        XCTAssertNil(viewModel.verificationCodeDestination)
        XCTAssertEqual(viewModel.password, "")
    }

    // MARK: - Helpers

    private func makeViewModel(service: MockAuthenticationService) -> UserLoginVM {
        // A coordinator that is not a GlacierAppRootCoordinator makes every
        // navigation, alert and progress call a no-op, which is what keeps these
        // tests off the app's real UI stack.
        let coordinator = StubRootCoordinator()
        return UserLoginVM(
            rootCoodinator: coordinator,
            passwordResetCoordinator: coordinator,
            authenticationService: service
        )
    }

    /// The view model does its work in a `Task`. Both it and this test run on the
    /// main actor, so yielding lets that task make progress.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }
}

private final class MockAuthenticationService: GlacierAuthenticationService, @unchecked Sendable {

    var signInResult: AuthSignInResult?
    var confirmSignInResult: AuthSignInResult?

    private(set) var requestedFlows: [GlacierSignInFlow] = []
    private(set) var submittedCodes: [String] = []

    func signIn(with email: String, password: String, flow: GlacierSignInFlow) async throws -> AuthSignInResult? {
        requestedFlows.append(flow)
        return signInResult
    }

    func confirmSignIn(challengeResponse: String) async throws -> AuthSignInResult? {
        submittedCodes.append(challengeResponse)
        return confirmSignInResult
    }

    // Unused by these tests.
    func createUserAccount(with email: String, password: String) async throws -> AuthSignUpResult? { nil }
    func resendSignUpCode(for userName: String) async throws -> AuthCodeDeliveryDetails {
        throw UserAuthenticationError.authenticationFailure
    }
    func confirmSignUp(for userName: String, confirmationCode: String) async throws -> AuthSignUpResult? { nil }
    func signIn(with provider: AuthProvider) async throws -> AuthSignInResult? { nil }
    func resetPassword(for userName: String) async throws -> AuthResetPasswordResult? { nil }
    func confirmResetPassword(for userName: String, with newPassword: String, confirmationCode: String) async throws -> Bool { false }
    func getCurrentUser() async throws -> AuthUser { throw UserAuthenticationError.authenticationFailure }
    func getCurrentAuthSession() async throws -> AuthSession? { nil }
    func signOut() async -> Bool { true }
    func deleteUser() async throws {}
}

private final class StubRootCoordinator: GlacierRootCoordinator {
    var path = NavigationPath()
    var sheet: Sheet?
    var currentScreen: GlacierScreen?
    var presentedScreen: GlacierScreen?

    func setScreen(_ screen: GlacierScreen) { currentScreen = screen }
    func presentScreen(_ screen: GlacierScreen) { presentedScreen = screen }
    func dismissPresentedScreen() { presentedScreen = nil }
    func presentRootScreen() {}
    func presentSheet(_ sheet: Sheet) { self.sheet = sheet }
    func dismissSheet() { sheet = nil }
    func presentPopup(with configuration: PopupConfiguration) {}
    func dismissPopup() {}
    func presentProgressIndicator() {}
    func dismissProgressIndicator() {}
}

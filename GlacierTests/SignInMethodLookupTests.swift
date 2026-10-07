import XCTest
import Amplify
import AWSCognitoAuthPlugin
import SwiftUI
@testable import Glacier

/// Covers the sign-in method lookup on the login path: reading the backend's
/// answer, choosing the message after a rejected password, and when the login
/// screen shows the Google and Apple options.
@MainActor
final class SignInMethodLookupTests: XCTestCase {

    override func tearDown() {
        UserDefaultsService.shared.remove(for: \.userEmail)
        UserDefaultsService.shared.remove(for: \.isUserAccountCreated)
        UserDefaultsService.shared.remove(for: \.isUserAccountConfirmed)
        super.tearDown()
    }

    // MARK: - Response parsing

    func testPasswordResponseReadsAsPassword() {
        XCTAssertEqual(SignInMethod(responseData: json(#"{"action":"PASSWORD"}"#)), .password)
    }

    func testFederatedResponsesReadAsTheirProvider() {
        XCTAssertEqual(
            SignInMethod(responseData: json(#"{"action":"FEDERATED_REDIRECT","provider":"Google"}"#)),
            .federated(.google)
        )
        XCTAssertEqual(
            SignInMethod(responseData: json(#"{"action":"FEDERATED_REDIRECT","provider":"Apple"}"#)),
            .federated(.apple)
        )
    }

    /// A provider this build doesn't know must not send the user anywhere.
    func testUnknownProviderReadsAsPassword() {
        XCTAssertEqual(
            SignInMethod(responseData: json(#"{"action":"FEDERATED_REDIRECT","provider":"Facebook"}"#)),
            .password
        )
    }

    func testMalformedResponsesReadAsPassword() {
        XCTAssertEqual(SignInMethod(responseData: json(#"{"action":"FEDERATED_REDIRECT"}"#)), .password)
        XCTAssertEqual(SignInMethod(responseData: json("not json")), .password)
        XCTAssertEqual(SignInMethod(responseData: Data()), .password)
    }

    // MARK: - Rejected credentials

    func testNotAuthorizedIsRejectedCredentials() {
        let error = AuthError.notAuthorized("Incorrect username or password.", "", nil)
        XCTAssertTrue(UserLoginVM.isRejectedCredentials(error))
    }

    func testUserNotFoundIsRejectedCredentials() {
        let error = AuthError.service("User does not exist.", "", AWSCognitoAuthError.userNotFound)
        XCTAssertTrue(UserLoginVM.isRejectedCredentials(error))
    }

    func testOtherServiceErrorsAreNotRejectedCredentials() {
        let error = AuthError.service("Invalid parameter", "", AWSCognitoAuthError.invalidParameter)
        XCTAssertFalse(UserLoginVM.isRejectedCredentials(error))
    }

    // MARK: - Messages

    func testLinkedProviderMessageNamesTheProviderAndKeepsThePasswordOption() {
        let alert = UserLoginVM.rejectedPasswordAlert(
            for: .federated(.google),
            errorDescription: "Incorrect username or password."
        )
        XCTAssertEqual(alert.title, "Linked to Google")
        XCTAssertEqual(alert.message, "This email is linked to Google. Sign in with Google, or check your password.")
    }

    func testPasswordMessageKeepsCognitosErrorAndAddsTheHint() {
        let alert = UserLoginVM.rejectedPasswordAlert(
            for: .password,
            errorDescription: "Incorrect username or password."
        )
        XCTAssertEqual(alert.title, "Couldn't log in")
        XCTAssertEqual(
            alert.message,
            "Incorrect username or password.\n\nIf you signed up with Apple or Google, use those buttons instead."
        )
    }

    // MARK: - Login screen state

    func testFinishingTheEmailStepShowsTheLinkedProvider() async {
        let lookup = MockSignInMethodLookup(method: .federated(.apple))
        let viewModel = makeViewModel(lookup: lookup)
        viewModel.email = "Person@Example.com "

        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .apple }

        XCTAssertTrue(viewModel.shouldShowLinkedProviderOnly)
        XCTAssertEqual(lookup.requestedEmails, ["person@example.com"])
    }

    /// An account created with a password and linked later still has one.
    func testUsePasswordInsteadBringsThePasswordStepBack() async {
        let viewModel = makeViewModel(lookup: MockSignInMethodLookup(method: .federated(.apple)))
        viewModel.email = "person@example.com"
        viewModel.signInWithEmail()
        await waitUntil { viewModel.shouldShowLinkedProviderOnly }

        viewModel.usePasswordInstead()

        XCTAssertFalse(viewModel.shouldShowLinkedProviderOnly)
        XCTAssertEqual(viewModel.linkedProvider, .apple)
    }

    func testEditingTheEmailAfterUsePasswordInsteadStartsOver() async {
        let viewModel = makeViewModel(lookup: MockSignInMethodLookup(method: .federated(.apple)))
        viewModel.email = "person@example.com"
        viewModel.signInWithEmail()
        await waitUntil { viewModel.shouldShowLinkedProviderOnly }
        viewModel.usePasswordInstead()

        viewModel.email = "someone.else@example.com"
        viewModel.email = "person@example.com"
        viewModel.signInWithEmail()
        await waitUntil { viewModel.shouldShowLinkedProviderOnly }
    }

    func testPasswordAccountShowsNoNoticeAfterTheEmailStep() async {
        let lookup = MockSignInMethodLookup(method: .password)
        let viewModel = makeViewModel(lookup: lookup)
        viewModel.email = "person@example.com"

        viewModel.signInWithEmail()
        await waitUntil { lookup.requestedEmails.count == 1 }
        await Task.yield()

        XCTAssertNil(viewModel.linkedProvider)
        XCTAssertFalse(viewModel.shouldShowFederatedSignInOptions)
    }

    func testEditingTheEmailClearsTheLinkedProvider() async {
        let viewModel = makeViewModel(lookup: MockSignInMethodLookup(method: .federated(.google)))
        viewModel.email = "person@example.com"
        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .google }

        viewModel.email = "someone.else@example.com"

        XCTAssertNil(viewModel.linkedProvider)
    }

    func testRejectedPasswordForAPasswordAccountBringsBackTheSocialButtons() async {
        let lookup = MockSignInMethodLookup(method: .password)
        let service = ThrowingAuthenticationService(
            error: AuthError.notAuthorized("Incorrect username or password.", "", nil)
        )
        let viewModel = makeViewModel(lookup: lookup, service: service)
        viewModel.email = "person@example.com"
        viewModel.signInWithEmail()
        viewModel.password = "wrong-password"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.shouldShowFederatedSignInOptions }

        // The email step's lookup is reused, not repeated.
        XCTAssertEqual(lookup.requestedEmails, ["person@example.com"])
    }

    func testRejectedPasswordForALinkedAccountShowsTheProviderNotTheButtons() async {
        let service = ThrowingAuthenticationService(
            error: AuthError.notAuthorized("Incorrect username or password.", "", nil)
        )
        let viewModel = makeViewModel(lookup: MockSignInMethodLookup(method: .federated(.google)), service: service)
        viewModel.email = "person@example.com"
        viewModel.password = "wrong-password"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .google }

        XCTAssertFalse(viewModel.shouldShowFederatedSignInOptions)
        // They have just used the password field, so it stays.
        XCTAssertFalse(viewModel.shouldShowLinkedProviderOnly)
    }

    /// Only a rejected email/password is worth a lookup. Anything else is not
    /// about which method the account uses.
    func testOtherSignInErrorsDoNotLookUpTheMethod() async {
        let lookup = MockSignInMethodLookup(method: .federated(.google))
        let service = ThrowingAuthenticationService(
            error: AuthError.service("Invalid parameter", "", AWSCognitoAuthError.invalidParameter)
        )
        let viewModel = makeViewModel(lookup: lookup, service: service)
        viewModel.email = "person@example.com"
        viewModel.password = "a-password"

        viewModel.signInWithEmail()
        await waitUntil { service.attempts == 1 }
        await Task.yield()

        XCTAssertEqual(lookup.requestedEmails, [])
        XCTAssertNil(viewModel.linkedProvider)
    }

    func testLastSignInProviderIsPassedThrough() {
        let viewModel = makeViewModel(lookup: MockSignInMethodLookup(method: .password), lastSignInProvider: .apple)
        XCTAssertEqual(viewModel.lastSignInProvider, .apple)
    }

    // MARK: - Sign-up refused by the pre-signup Lambda

    /// How Amplify reports it on email sign-up.
    func testReasonIsReadFromAnEmailSignUpRejection() {
        let error = AuthError.service(
            "PreSignUp failed with error An account with this email already uses Sign in with Google.",
            "",
            AWSCognitoAuthError.lambda
        )
        XCTAssertEqual(
            PreSignUpRejection.reason(from: error),
            "An account with this email already uses Sign in with Google."
        )
    }

    /// How it arrives from the Hosted UI redirect: Cognito's error code in
    /// front and `+` for spaces.
    func testUnverifiedAccountIsRecognisedInAHostedUIRejection() {
        let error = AuthError.service(
            "invalid_request PreSignUp+failed+with+error+Verify+your+existing+account+before+using+social+sign-in.+",
            ""
        )
        XCTAssertEqual(
            PreSignUpRejection.federatedSignInAlert(for: error, provider: .google)?.title,
            "Verify your account"
        )
        XCTAssertEqual(
            PreSignUpRejection.federatedSignInAlert(for: error, provider: .google)?.message,
            "This email already has a Glacier account that isn't verified yet. Log in with your email and password to finish verifying it, then try Google again."
        )
    }

    func testOtherLambdaReasonsAreShownAsWritten() {
        let error = AuthError.service(
            "invalid_request PreSignUp failed with error We couldn't safely sign you in. Please try again.",
            ""
        )
        XCTAssertEqual(
            PreSignUpRejection.federatedSignInAlert(for: error, provider: .apple),
            AuthAlertContent(title: "Couldn't sign in", message: "We couldn't safely sign you in. Please try again.")
        )
    }

    func testErrorsFromElsewhereAreNotRejections() {
        let error = AuthError.service("access_denied User cancelled", "")
        XCTAssertNil(PreSignUpRejection.reason(from: error))
        XCTAssertNil(PreSignUpRejection.federatedSignInAlert(for: error, provider: .google))
    }

    func testExistingProviderMessageNamesTheProvider() {
        XCTAssertEqual(
            PreSignUpRejection.existingProviderAlert(for: .apple),
            AuthAlertContent(
                title: "Account already exists",
                message: "An account with this email already uses Apple. Continue with Apple instead."
            )
        )
    }

    func testRefusedSignUpForAGoogleEmailOffersGoogle() async {
        let lookup = MockSignInMethodLookup(method: .federated(.google))
        let viewModel = makeRegistrationViewModel(lookup: lookup)
        viewModel.email = "person@example.com"
        viewModel.password = "Valid-password1!"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .google }

        XCTAssertEqual(lookup.requestedEmails, ["person@example.com"])
    }

    /// A password sign-up for a Google or Apple email is always refused, so
    /// the sign-up screen says so as soon as the email step is done.
    func testFinishingTheSignUpEmailStepShowsTheLinkedProvider() async {
        let lookup = MockSignInMethodLookup(method: .federated(.apple))
        let viewModel = makeRegistrationViewModel(lookup: lookup)
        viewModel.email = "person@example.com"

        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .apple }

        XCTAssertTrue(viewModel.shouldShowLinkedProviderOnly)
        XCTAssertEqual(lookup.requestedEmails, ["person@example.com"])
    }

    func testRefusedSignUpReusesTheEmailStepLookup() async {
        let lookup = MockSignInMethodLookup(method: .federated(.google))
        let service = Self.refusingSignUpService()
        let viewModel = makeRegistrationViewModel(lookup: lookup, service: service)
        viewModel.email = "person@example.com"
        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .google }

        viewModel.password = "Valid-password1!"
        viewModel.signInWithEmail()
        await waitUntil { service.signUpAttempts == 1 }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(lookup.requestedEmails, ["person@example.com"])
        XCTAssertEqual(viewModel.linkedProvider, .google)
    }

    func testRefusedSignUpForAnyOtherReasonOffersNoProvider() async {
        let lookup = MockSignInMethodLookup(method: .password)
        let viewModel = makeRegistrationViewModel(lookup: lookup)
        viewModel.email = "person@example.com"
        viewModel.password = "Valid-password1!"

        viewModel.signInWithEmail()
        await waitUntil { lookup.requestedEmails.count == 1 }
        await Task.yield()

        XCTAssertNil(viewModel.linkedProvider)
    }

    func testEditingTheEmailClearsTheRefusedSignUpProvider() async {
        let viewModel = makeRegistrationViewModel(lookup: MockSignInMethodLookup(method: .federated(.apple)))
        viewModel.email = "person@example.com"
        viewModel.password = "Valid-password1!"
        viewModel.signInWithEmail()
        await waitUntil { viewModel.linkedProvider == .apple }

        viewModel.email = "someone.else@example.com"

        XCTAssertNil(viewModel.linkedProvider)
        XCTAssertFalse(viewModel.shouldShowLinkedProviderOnly)
    }

    // MARK: - Unverified account

    /// Amplify reports an unverified account as a `confirmSignUp` step once the
    /// password is right. The login must hand over to the confirmation screen
    /// with what it needs, instead of showing a generic failure.
    func testLoginToAnUnverifiedAccountSetsUpAccountConfirmation() async {
        let service = UnverifiedAccountAuthenticationService()
        let savedPassword = SavedPassword()
        let coordinator = LookupStubRootCoordinator()
        let viewModel = UserLoginVM(
            rootCoodinator: coordinator,
            passwordResetCoordinator: coordinator,
            authenticationService: service,
            signInMethodService: MockSignInMethodLookup(method: .password),
            lastSignInProvider: nil,
            pendingCredentialStore: savedPassword.access
        )
        viewModel.email = " person@example.com "
        viewModel.password = "Valid-password1!"

        viewModel.signInWithEmail()
        await waitUntil { service.resentCodeFor == ["person@example.com"] }

        XCTAssertEqual(savedPassword.value, "Valid-password1!")
        XCTAssertEqual(UserDefaultsService.shared.get(for: \.userEmail) as String?, "person@example.com")
        XCTAssertEqual(UserDefaultsService.shared.get(for: \.isUserAccountCreated) as Bool?, true)
        XCTAssertEqual(UserDefaultsService.shared.get(for: \.isUserAccountConfirmed) as Bool?, false)
        XCTAssertFalse(viewModel.isAwaitingVerificationCode)
    }

    // MARK: - Helpers

    /// `nonisolated` because it's the default argument of `makeRegistrationViewModel`, and default
    /// arguments are evaluated outside the class's main-actor isolation. It only builds a plain
    /// service object, so it needs no isolation.
    nonisolated private static func refusingSignUpService() -> ThrowingAuthenticationService {
        ThrowingAuthenticationService(
            error: AuthError.service(
                "PreSignUp failed with error An account with this email already uses Sign in with Google.",
                "",
                AWSCognitoAuthError.lambda
            )
        )
    }

    private func makeRegistrationViewModel(
        lookup: MockSignInMethodLookup,
        service: ThrowingAuthenticationService = SignInMethodLookupTests.refusingSignUpService()
    ) -> UserRegistrationVM {
        UserRegistrationVM(
            rootCoodinator: LookupStubRootCoordinator(),
            authenticationService: service,
            postAuthenticationBootstrap: {},
            signInMethodService: lookup
        )
    }

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func makeViewModel(
        lookup: MockSignInMethodLookup,
        service: GlacierAuthenticationService = ThrowingAuthenticationService(
            error: AuthError.unknown("unused", nil)
        ),
        lastSignInProvider: FederatedSignInProvider? = nil
    ) -> UserLoginVM {
        // A coordinator that is not a GlacierAppRootCoordinator makes every
        // navigation, alert and progress call a no-op.
        let coordinator = LookupStubRootCoordinator()
        return UserLoginVM(
            rootCoodinator: coordinator,
            passwordResetCoordinator: coordinator,
            authenticationService: service,
            signInMethodService: lookup,
            lastSignInProvider: lastSignInProvider
        )
    }

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

private final class MockSignInMethodLookup: SignInMethodLookup, @unchecked Sendable {
    let method: SignInMethod
    private let lock = NSLock()
    private var emails: [String] = []

    var requestedEmails: [String] {
        lock.lock(); defer { lock.unlock() }
        return emails
    }

    init(method: SignInMethod) {
        self.method = method
    }

    func signInMethod(for email: String) async -> SignInMethod {
        lock.lock()
        emails.append(email)
        lock.unlock()
        return method
    }
}

private final class ThrowingAuthenticationService: GlacierAuthenticationService, @unchecked Sendable {
    let error: Error
    private(set) var attempts = 0

    init(error: Error) {
        self.error = error
    }

    func signIn(with email: String, password: String, flow: GlacierSignInFlow) async throws -> AuthSignInResult? {
        attempts += 1
        throw error
    }

    private(set) var signUpAttempts = 0

    func createUserAccount(with email: String, password: String) async throws -> AuthSignUpResult? {
        signUpAttempts += 1
        throw error
    }

    // Unused by these tests.
    func confirmSignIn(challengeResponse: String) async throws -> AuthSignInResult? { nil }
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

private final class UnverifiedAccountAuthenticationService: GlacierAuthenticationService, @unchecked Sendable {
    private(set) var resentCodeFor: [String] = []

    func signIn(with email: String, password: String, flow: GlacierSignInFlow) async throws -> AuthSignInResult? {
        AuthSignInResult(nextStep: .confirmSignUp(nil))
    }

    func resendSignUpCode(for userName: String) async throws -> AuthCodeDeliveryDetails {
        resentCodeFor.append(userName)
        return AuthCodeDeliveryDetails(destination: .email("p***n@example.com"))
    }

    // Unused by these tests.
    func confirmSignIn(challengeResponse: String) async throws -> AuthSignInResult? { nil }
    func createUserAccount(with email: String, password: String) async throws -> AuthSignUpResult? { nil }
    func confirmSignUp(for userName: String, confirmationCode: String) async throws -> AuthSignUpResult? { nil }
    func signIn(with provider: AuthProvider) async throws -> AuthSignInResult? { nil }
    func resetPassword(for userName: String) async throws -> AuthResetPasswordResult? { nil }
    func confirmResetPassword(for userName: String, with newPassword: String, confirmationCode: String) async throws -> Bool { false }
    func getCurrentUser() async throws -> AuthUser { throw UserAuthenticationError.authenticationFailure }
    func getCurrentAuthSession() async throws -> AuthSession? { nil }
    func signOut() async -> Bool { true }
}

/// In memory, because the real store's shared Keychain group needs signing
/// entitlements the unit-test run doesn't have.
private final class SavedPassword: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var access: PendingSignupCredentialAccess {
        PendingSignupCredentialAccess(
            save: { [self] password in lock.lock(); stored = password; lock.unlock() },
            read: { [self] in value },
            clear: { [self] in lock.lock(); stored = nil; lock.unlock() }
        )
    }
}

private final class LookupStubRootCoordinator: GlacierRootCoordinator {
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

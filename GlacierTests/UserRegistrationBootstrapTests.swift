import XCTest
import Amplify
import SwiftUI
@testable import Glacier

@MainActor
final class UserRegistrationBootstrapTests: XCTestCase {

    override func tearDown() {
        UserDefaultsService.shared.remove(for: \.userEmail)
        UserDefaultsService.shared.remove(for: \.isUserLoggedIn)
        super.tearDown()
    }

    func testHostedProviderWaitsForBootstrapBeforeRouting() async {
        let service = RegistrationAuthenticationService()
        service.providerSignInResult = AuthSignInResult(nextStep: .done)
        let gate = RegistrationBootstrapGate()
        let progress = RegistrationProgressRecorder()
        let (viewModel, coordinator) = makeViewModel(service: service, gate: gate, progress: progress)

        viewModel.signInWith(.apple)
        await waitUntil { gate.didStart }

        XCTAssertTrue(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true])
        XCTAssertNil(coordinator.currentScreen)
        gate.release()
        await waitUntil { coordinator.currentScreen == .userOnboarding }
        XCTAssertFalse(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true, false])
    }

    func testImmediateSignUpWaitsForBootstrapBeforeRouting() async {
        let service = RegistrationAuthenticationService()
        service.signUpResult = AuthSignUpResult(.done)
        service.passwordSignInResult = AuthSignInResult(nextStep: .done)
        let gate = RegistrationBootstrapGate()
        let progress = RegistrationProgressRecorder()
        let (viewModel, coordinator) = makeViewModel(service: service, gate: gate, progress: progress)
        viewModel.email = "person@example.com"
        viewModel.password = "Valid-password1!"

        viewModel.signInWithEmail()
        await waitUntil { gate.didStart }

        XCTAssertEqual(service.requestedFlows, [.passwordOnly])
        XCTAssertEqual(service.requestedCredentials, [.init(email: "person@example.com", password: "Valid-password1!")])
        XCTAssertTrue(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true])
        XCTAssertNil(coordinator.currentScreen)
        gate.release()
        await waitUntil { coordinator.currentScreen == .userOnboarding }
        XCTAssertFalse(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true, false])
    }

    func testImmediateSignUpRoutesToLoginWhenPasswordSignInFails() async {
        let service = RegistrationAuthenticationService()
        service.signUpResult = AuthSignUpResult(.done)
        service.passwordSignInResult = nil
        let gate = RegistrationBootstrapGate()
        let progress = RegistrationProgressRecorder()
        let (viewModel, coordinator) = makeViewModel(service: service, gate: gate, progress: progress)
        viewModel.email = "person@example.com"
        viewModel.password = "Valid-password1!"

        viewModel.signInWithEmail()
        await waitUntil { coordinator.currentScreen == .userAuthentication }

        XCTAssertEqual(service.requestedFlows, [.passwordOnly])
        XCTAssertFalse(gate.didStart)
        XCTAssertFalse(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true, false])
    }

    func testPostConfirmationAutoLoginWaitsForBootstrapBeforeRouting() async {
        let service = RegistrationAuthenticationService()
        service.confirmSignUpResult = AuthSignUpResult(.done)
        service.passwordSignInResult = AuthSignInResult(nextStep: .done)
        let gate = RegistrationBootstrapGate()
        let progress = RegistrationProgressRecorder()
        // Seed the pending sign-up password through an in-memory store instead of the real
        // Keychain: the Keychain uses a shared access group that requires code-signing
        // entitlements, which the CODE_SIGNING_ALLOWED=NO unit-test run does not apply.
        let credentialStore = InMemoryPendingCredentialStore()
        credentialStore.seed("Valid-password1!")
        let (viewModel, coordinator) = makeViewModel(service: service, gate: gate, progress: progress, credentialStore: credentialStore)
        UserDefaultsService.shared.set("person@example.com", for: \.userEmail)

        viewModel.confirmAccount(userName: "person@example.com", confirmationCode: "123456")
        await waitUntil { gate.didStart }

        XCTAssertEqual(service.requestedFlows, [.passwordOnly])
        XCTAssertTrue(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true])
        XCTAssertNil(coordinator.currentScreen)
        gate.release()
        await waitUntil { coordinator.currentScreen == .userOnboarding }
        XCTAssertFalse(progress.isPresented)
        XCTAssertEqual(progress.transitions, [true, false])
    }

    private func makeViewModel(
        service: RegistrationAuthenticationService,
        gate: RegistrationBootstrapGate,
        progress: RegistrationProgressRecorder,
        credentialStore: InMemoryPendingCredentialStore = InMemoryPendingCredentialStore()
    ) -> (UserRegistrationVM, GlacierAppRootCoordinator) {
        let coordinator = GlacierAppRootCoordinator()
        let viewModel = UserRegistrationVM(
            rootCoodinator: coordinator,
            authenticationService: service,
            postAuthenticationBootstrap: { await gate.run() },
            registrationProgressChanged: { progress.isPresented = $0 },
            pendingCredentialStore: credentialStore.access
        )
        return (viewModel, coordinator)
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

@MainActor
private final class RegistrationProgressRecorder {
    private(set) var transitions: [Bool] = []
    var isPresented = false {
        didSet { transitions.append(isPresented) }
    }
}

/// In-memory stand-in for `PendingSignupCredentialStore`, injected via
/// `PendingSignupCredentialAccess` so the post-confirmation auto-login path can read back a
/// seeded password without the real Keychain (unavailable under CODE_SIGNING_ALLOWED=NO).
private final class InMemoryPendingCredentialStore: @unchecked Sendable {
    private var storedPassword: String?

    func seed(_ password: String) { storedPassword = password }

    var access: PendingSignupCredentialAccess {
        PendingSignupCredentialAccess(
            save: { self.storedPassword = $0 },
            read: { self.storedPassword },
            clear: { self.storedPassword = nil }
        )
    }
}

@MainActor
private final class RegistrationBootstrapGate {
    private(set) var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        didStart = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class RegistrationAuthenticationService: GlacierAuthenticationService, @unchecked Sendable {
    struct Credentials: Equatable {
        let email: String
        let password: String
    }

    var signUpResult: AuthSignUpResult?
    var confirmSignUpResult: AuthSignUpResult?
    var passwordSignInResult: AuthSignInResult?
    var providerSignInResult: AuthSignInResult?
    private(set) var requestedFlows: [GlacierSignInFlow] = []
    private(set) var requestedCredentials: [Credentials] = []

    func createUserAccount(with email: String, password: String) async throws -> AuthSignUpResult? { signUpResult }
    func confirmSignUp(for userName: String, confirmationCode: String) async throws -> AuthSignUpResult? { confirmSignUpResult }
    func signIn(with email: String, password: String, flow: GlacierSignInFlow) async throws -> AuthSignInResult? {
        requestedFlows.append(flow)
        requestedCredentials.append(.init(email: email, password: password))
        return passwordSignInResult
    }
    func signIn(with provider: AuthProvider) async throws -> AuthSignInResult? { providerSignInResult }
    func resendSignUpCode(for userName: String) async throws -> AuthCodeDeliveryDetails { throw UserAuthenticationError.authenticationFailure }
    func confirmSignIn(challengeResponse: String) async throws -> AuthSignInResult? { nil }
    func resetPassword(for userName: String) async throws -> AuthResetPasswordResult? { nil }
    func confirmResetPassword(for userName: String, with newPassword: String, confirmationCode: String) async throws -> Bool { false }
    func getCurrentUser() async throws -> AuthUser { throw UserAuthenticationError.authenticationFailure }
    func getCurrentAuthSession() async throws -> AuthSession? { nil }
    func signOut() async -> Bool { true }
}

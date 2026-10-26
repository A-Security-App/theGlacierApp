//
//  DiscoverySurveyService.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Alamofire

/**
 DiscoverySurveyService decides whether the last onboarding screen asks "How did you first hear
 about Glacier?", and sends the answer.

 The backend owns the decision, so an answer or Skip on the website, Android or another device
 stops iOS asking too. Nothing here may slow onboarding down: the status is fetched in the
 background while the user is still on earlier onboarding screens, and if it isn't known by the
 time onboarding ends, the question is simply not asked.

 Backend contract:
   GET  {consoleBaseEndpoint}/user/acquisition-survey   (no query parameters; any are rejected)
        → { "state": "unanswered" | "submitted" | "skipped", "eligible": true | false }
   POST {consoleBaseEndpoint}/user/acquisition-survey
        { "surface": "ios", "action": "submit" | "skip", "channel"?: "<DiscoveryChannel>", "detail"?: "<≤160 code points>" }
        The first write wins; later writes return the stored state.
   Authorization: Bearer <Cognito access token>

 The backend reports `eligible: false` until the survey is switched on, so the screen never shows
 before then.
 In Debug builds, launch with `-GlacierForceDiscoverySurvey YES` to show it anyway.

 Call it from the main thread only, like the onboarding view models that use it.
 */
final class DiscoverySurveyService {

    // MARK: - Public properties

    static let shared = DiscoverySurveyService()

    /// Whether onboarding should end on the survey screen. `false` until the backend has said so.
    var shouldAsk: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "GlacierForceDiscoverySurvey") { return true }
        #endif
        return status == .ask
    }

    // MARK: - Private properties

    private enum Status {
        case unknown, ask, dontAsk
    }

    private struct StatusResponse: Decodable {
        let state: String
        let eligible: Bool
    }

    /// Path (relative to the console base endpoint) for the survey resource.
    private static let surveyPath = "user/acquisition-survey"
    private static let surface = "ios"
    private static let maxSendAttempts = 3

    private var status: Status = .unknown
    private var statusTask: Task<Void, Never>?
    /// Bumped by `reset()` so a request started for a previous account can't change this one's state.
    private var generation = 0

    private let sessionManager = Alamofire.Session(
        configuration: URLSessionConfiguration.ephemeral,
        serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
    )

    // MARK: - Initializer

    private init() {}

    // MARK: - Public methods

    /// Forgets everything known about the current account. Called whenever onboarding starts, so
    /// a different account signing in never inherits the previous one's answer.
    func reset() {
        generation += 1
        statusTask?.cancel()
        statusTask = nil
        status = .unknown
    }

    /// Fetches the status in the background if it isn't known yet. Safe to call repeatedly: each
    /// onboarding step calls it, so a fetch that failed on a bad connection is retried later.
    func prefetchStatus() {
        guard status == .unknown, statusTask == nil else { return }
        let generation = generation
        statusTask = Task { @MainActor [weak self] in
            let fetched = await self?.fetchStatus()
            guard let self, self.generation == generation else { return }
            self.statusTask = nil
            if let fetched {
                self.status = fetched
            }
        }
    }

    /// Records the answer, or a skip when `answer` is `nil`. Returns at once: the request runs in
    /// the background, so the user is never kept waiting on the network. The answer is held only
    /// in memory, and is lost if every attempt fails, which is fine for an optional question.
    func send(_ answer: DiscoverySurveyAnswer?) {
        status = .dontAsk
        var body: [String: String] = ["surface": Self.surface, "action": answer == nil ? "skip" : "submit"]
        if let answer {
            body["channel"] = answer.channel.rawValue
            body["detail"] = answer.detail
        }
        Task { @MainActor [weak self] in
            for attempt in 1...Self.maxSendAttempts {
                guard let self else { return }
                if await self.post(body) == .done { return }
                guard attempt < Self.maxSendAttempts else { break }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
            Log.general.error("DiscoverySurveyService: gave up sending the survey response.")
        }
    }

    // MARK: - Private methods

    private func fetchStatus() async -> Status? {
        guard !SecurityCenter.isProxyDetected,
              let url = EndpointService.shared.endpointURL(path: Self.surveyPath),
              let headers = await GlacierAPIHeaders.authHeaders()
        else { return nil }

        let response = await sessionManager.request(
            url,
            method: .get,
            headers: headers,
            requestModifier: { $0.timeoutInterval = 15 }
        )
        .validate()
        .serializingDecodable(StatusResponse.self)
        .response

        switch response.result {
        case .success(let decoded):
            return decoded.eligible && decoded.state == "unanswered" ? .ask : .dontAsk
        case .failure(let error):
            Log.general.notice("DiscoverySurveyService: status unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private enum PostResult {
        /// Saved, or rejected in a way retrying won't fix (bad input, or the session is gone).
        case done
        case retry
    }

    /// Never logs the body: the detail is free text the user typed.
    private func post(_ body: [String: String]) async -> PostResult {
        guard !SecurityCenter.isProxyDetected,
              let url = EndpointService.shared.endpointURL(path: Self.surveyPath),
              let headers = await GlacierAPIHeaders.authHeaders()
        else { return .retry }

        let response = await sessionManager.request(
            url,
            method: .post,
            parameters: body,
            encoder: JSONParameterEncoder.default,
            headers: headers,
            requestModifier: { $0.timeoutInterval = 15 }
        )
        .validate()
        .serializingData()
        .response

        switch response.result {
        case .success:
            return .done
        case .failure:
            if let code = response.response?.statusCode, (400..<500).contains(code) { return .done }
            return .retry
        }
    }
}

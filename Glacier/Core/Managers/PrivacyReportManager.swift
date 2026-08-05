//
//  PrivacyReportManager.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Alamofire

/**
 PrivacyReportManager talks to the backend endpoint that controls whether the
 signed-in user receives the Weekly Privacy Report email. That report is a short
 weekly recap of the user's protection — most notably how many web trackers the
 private DNS blocked over the past week.

 Backend contract:
   PUT {consoleBaseEndpoint}/v1/users/settings
   Authorization: Bearer <Cognito access token>
   Content-Type: application/json
   { "privacy_report_enabled": <Bool> }
 */
final class PrivacyReportManager {

    // MARK: - Public properties

    static let shared = PrivacyReportManager()

    // MARK: - Private properties

    /// Path (relative to the console base endpoint) for the user settings resource.
    private static let userSettingsPath = "v1/users/settings"

    /// JSON body key the backend expects for the privacy-report flag.
    private static let privacyReportEnabledKey = "privacy_report_enabled"

    private let sessionManager = Alamofire.Session(
        configuration: URLSessionConfiguration.ephemeral,
        serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
    )
    private let internalQueue = DispatchQueue(label: "privacy-report-queue", qos: .userInitiated)

    // MARK: - Initializer

    private init() {}

    // MARK: - Public methods

    /// Enables or disables the Weekly Privacy Report email for the signed-in user.
    /// Fire-and-forget by default; pass `completion` to observe the result.
    func setWeeklyPrivacyReport(enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { completion?(false); return }
        guard let url = EndpointService.shared.endpointURL(path: Self.userSettingsPath) else {
            Log.general.error("PrivacyReportManager: could not build user-settings URL.")
            completion?(false)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion?(false)
                return
            }
            self.sessionManager.request(
                url,
                method: .put,
                parameters: [Self.privacyReportEnabledKey: enabled],
                encoding: JSONEncoding.default,
                headers: headers
            )
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success:
                    completion?(true)
                case .failure(let error):
                    Log.general.error("PrivacyReportManager: failed to set privacy report enabled=\(enabled): \(error)")
                    completion?(false)
                }
            }
        }
    }
}

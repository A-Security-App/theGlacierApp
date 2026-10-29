//
//  VoicemailSettingsManager.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Alamofire

/**
 VoicemailSettingsManager talks to the backend endpoint that controls whether
 unanswered calls to each of the signed-in user's Glacier numbers go to voicemail.

 Backend contract:
   PUT {consoleBaseEndpoint}users/settings
   Authorization: Bearer <Cognito access token>
   Content-Type: application/json
   { "phone_number": "<E.164>", "voicemail_enabled": <Bool> }

   GET {consoleBaseEndpoint}users/settings
   Authorization: Bearer <Cognito access token>
   -> { "data": { "settings": { "voicemail_numbers": [
          { "phone_number": "<E.164>", "voicemail_enabled": <Bool> }, ...
      ] } } }

 A number missing from `voicemail_numbers` has voicemail on — the backend's default.
 */
final class VoicemailSettingsManager {

    // MARK: - Response models

    /// Decodes the subset of `GET users/settings` we care about.
    private struct UserSettingsResponse: Decodable {
        struct DataObject: Decodable {
            struct Settings: Decodable {
                struct VoicemailNumber: Decodable {
                    let phoneNumber: String
                    let voicemailEnabled: Bool

                    enum CodingKeys: String, CodingKey {
                        case phoneNumber = "phone_number"
                        case voicemailEnabled = "voicemail_enabled"
                    }
                }
                let voicemailNumbers: [VoicemailNumber]

                enum CodingKeys: String, CodingKey {
                    case voicemailNumbers = "voicemail_numbers"
                }
            }
            let settings: Settings
        }
        let data: DataObject
    }

    // MARK: - Public properties

    static let shared = VoicemailSettingsManager()

    /// Voicemail is on for any number the backend hasn't stored a value for.
    static let defaultVoicemailEnabled = true

    // MARK: - Private properties

    /// Path (relative to the console base endpoint, which already ends in `/api/v1/`)
    /// for the user settings resource.
    private static let userSettingsPath = "users/settings"

    /// JSON body keys the backend expects for a per-number voicemail change.
    private static let phoneNumberKey = "phone_number"
    private static let voicemailEnabledKey = "voicemail_enabled"

    private let sessionManager = Alamofire.Session(
        configuration: URLSessionConfiguration.ephemeral,
        serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
    )
    private let internalQueue = DispatchQueue(label: "voicemail-settings-queue", qos: .userInitiated)

    // MARK: - Initializer

    private init() {}

    // MARK: - Public methods

    /// Last known value per number, cached locally so the UI can render immediately
    /// while the backend is consulted.
    var cachedVoicemailEnabledByNumber: [String: Bool] {
        UserDefaultsService.shared.get(for: \.voicemailEnabledByNumber) ?? [:]
    }

    /// Enables or disables voicemail for one of the signed-in user's numbers.
    /// The local cache is only updated once the backend accepts the change.
    func setVoicemail(enabled: Bool, for phoneNumber: String, completion: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { completion?(false); return }
        guard let url = EndpointService.shared.endpointURL(path: Self.userSettingsPath) else {
            Log.general.error("VoicemailSettingsManager: could not build user-settings URL.")
            completion?(false)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion?(false)
                return
            }
            let parameters: [String: Any] = [
                Self.phoneNumberKey: phoneNumber,
                Self.voicemailEnabledKey: enabled
            ]
            self.sessionManager.request(
                url,
                method: .put,
                parameters: parameters,
                encoding: JSONEncoding.default,
                headers: headers
            )
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success:
                    var cache = self.cachedVoicemailEnabledByNumber
                    cache[phoneNumber] = enabled
                    UserDefaultsService.shared.set(cache, for: \.voicemailEnabledByNumber)
                    completion?(true)
                case .failure(let error):
                    Log.general.error("VoicemailSettingsManager: failed to set voicemail enabled=\(enabled): \(error)")
                    completion?(false)
                }
            }
        }
    }

    /// Reads the voicemail flag for each of the signed-in user's numbers from the backend.
    /// Numbers missing from the result use `defaultVoicemailEnabled`.
    /// Calls back with `nil` on any failure — the caller should keep its current values.
    func fetchVoicemail(completion: @escaping ([String: Bool]?) -> Void) {
        guard !SecurityCenter.isProxyDetected else { completion(nil); return }
        guard let url = EndpointService.shared.endpointURL(path: Self.userSettingsPath) else {
            Log.general.error("VoicemailSettingsManager: could not build user-settings URL.")
            completion(nil)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion(nil)
                return
            }
            self.sessionManager.request(
                url,
                method: .get,
                encoding: URLEncoding.default,
                headers: headers
            )
            .validate()
            .responseDecodable(of: UserSettingsResponse.self, queue: self.internalQueue) { response in
                switch response.result {
                case .success(let payload):
                    let byNumber = Dictionary(
                        payload.data.settings.voicemailNumbers.map { ($0.phoneNumber, $0.voicemailEnabled) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                    UserDefaultsService.shared.set(byNumber, for: \.voicemailEnabledByNumber)
                    completion(byNumber)
                case .failure(let error):
                    Log.general.error("VoicemailSettingsManager: failed to fetch voicemail flags: \(error)")
                    completion(nil)
                }
            }
        }
    }
}

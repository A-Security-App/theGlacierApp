//
//  GlacierAPIHeaders.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Alamofire
import Amplify
import AWSPluginsCore

enum GlacierAPIHeaders {
    static func authHeaders() async -> HTTPHeaders? {
        // Use GlacierApplicationDelegate.shared instead of UIApplication.shared.delegate:
        // when @UIApplicationDelegateAdaptor is used, UIApplication.shared.delegate returns
        // SwiftUI's internal wrapper, not GlacierApplicationDelegate, so the cast always fails
        // and the guard never fires — causing a preconditionFailure in Amplify when
        // fetchAuthSession() is called before configure() has completed.
        guard GlacierApplicationDelegate.shared?.amplifyIsConfigured == true else {
            Log.auth.info("Skipping auth headers because Amplify is not configured yet.")
            return nil
        }

        // fetchAuthSession contacts AWS Cognito and can hang for ~60s on a dead network
        // (OS TCP timeout). Race it against an 8-second deadline so callers are never
        // blocked indefinitely; on timeout we return nil and fall through to cached state.
        do {
            return try await withThrowingTaskGroup(of: HTTPHeaders?.self) { group in
                group.addTask {
                    let session = try await Amplify.Auth.fetchAuthSession()
                    guard let provider = session as? AuthCognitoTokensProvider else { return nil }
                    let tokens = try provider.getCognitoTokens().get()
                    return HTTPHeaders(["Authorization": "Bearer \(tokens.accessToken)"])
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    return nil
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            Log.auth.error("authHeaders: fetchAuthSession error or timeout: \(error)")
            return nil
        }
    }
}

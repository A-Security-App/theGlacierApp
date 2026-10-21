//
//  DiscoverySurveyViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 DiscoverySurveyViewModel defines requirements for DiscoverySurveyScreen view model.
 */
protocol DiscoverySurveyViewModel: GlacierViewModelWithRootCoordinator, ObservableObject {
    var selectedChannel: DiscoveryChannel? { get }
    var detail: String { get set }

    func select(_ channel: DiscoveryChannel)
    func submit()
    func skip()
}

/**
 DiscoverySurveyVM provides data/state and business logic for DiscoverySurveyScreen, the last
 onboarding screen. Submit and Skip both finish onboarding straight away; the answer is sent in
 the background by `DiscoverySurveyService`.
 */
final class DiscoverySurveyVM: DiscoverySurveyViewModel {

    // MARK: - Public properties

    @Published private(set) var selectedChannel: DiscoveryChannel?
    @Published var detail: String = "" {
        didSet {
            let capped = DiscoverySurveyAnswer.capped(detail)
            if capped != detail { detail = capped }
        }
    }

    let rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    private let completionFlag: KeyPath<UserDefaultsService.LocalStorageKeys, String>
    private var isFinished = false

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator, completionFlag: KeyPath<UserDefaultsService.LocalStorageKeys, String>) {
        self.rootCoordinator = rootCoordinator
        self.completionFlag = completionFlag
    }

    // MARK: - Public methods

    func select(_ channel: DiscoveryChannel) {
        // Detail typed for another channel answers a different question, so it doesn't carry over.
        if channel != selectedChannel {
            detail = ""
        }
        selectedChannel = channel
    }

    func submit() {
        guard let selectedChannel else { return }
        finish(with: DiscoverySurveyAnswer(channel: selectedChannel, detail: detail))
    }

    func skip() {
        finish(with: nil)
    }

    // MARK: - Private methods

    private func finish(with answer: DiscoverySurveyAnswer?) {
        guard !isFinished else { return }
        isFinished = true
        DiscoverySurveyService.shared.send(answer)
        completeOnboarding(marking: completionFlag)
    }
}

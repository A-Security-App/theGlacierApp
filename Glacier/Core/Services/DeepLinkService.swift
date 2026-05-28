//
//  DeepLinkService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Combine

/**
 DeepLinkServiceProtocol defines requirements for services with deep links related APIs.
 */
protocol DeepLinkServiceProtocol {
    var linkPublisher: AnyPublisher<DeepLinkTarget, Never> { get }
    func handle(url: URL) -> Bool
}

/**
 DeepLinkService provides API for handling deep links passed to the app to identify targeted workflows.
 */
final class DeepLinkService: DeepLinkServiceProtocol {
    
    // MARK: - Public properties
    
    static let shared = DeepLinkService()
    
    // Public publisher for the UI to listen to
    var linkPublisher: AnyPublisher<DeepLinkTarget, Never> {
        linkSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Private properties
    
    // Internal subject to broadcast detected links
    private let linkSubject = PassthroughSubject<DeepLinkTarget, Never>()
    
    // MARK: - Initializer
    
    private init() {}
    
    // MARK: - Public methods
    
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let target = DeepLinkTarget.from(url: url) else {
            return false
        }
        
        linkSubject.send(target)
        return true
    }
}

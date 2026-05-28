//
//  FirstAppearModifier.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 26/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 FirstAppearMofier is used to identify first time appear event for a SwiftUI view and call the given action.
 */
public struct FirstAppearModifier: ViewModifier {
    
    // MARK: - Private properties
    
    private let action: () async -> Void
    @State private var hasAppeared = false
    
    // MARK: - Initializer
    
    public init(_ action: @escaping () async -> Void) {
        self.action = action
    }
    
    // MARK: - UI/UX
    
    public func body(content: Content) -> some View {
        content
            .task(priority: .userInitiated) {
                guard !hasAppeared else { return }
                hasAppeared = true
                await action()
            }
    }
}

public extension View {
    
    func onFirstAppear(_ action: @escaping () async -> Void) -> some View {
        modifier(FirstAppearModifier(action))
    }
}

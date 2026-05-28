//
//  GlacierMenuView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 04/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierMenuItem contains properties for menu items to show in GlacierMenuView
 */
struct GlacierMenuItem {
    let id: String = UUID().uuidString
    let icon: String?
    let title: String?
    let action: () -> Void
}

/**
 GlacierMenuView presents a custom menu with given list of menu items.
 */
struct GlacierMenuView: View {
    
    // MARK: - Public properties
    
    var menuItems: [GlacierMenuItem] = []

    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    
    @State private var isAppearing = false
    @State private var forgroundColor: Color?
    
    // MARK: UI/UX
    
    var body: some View {
        GlacierViewContainer(darkColor: .white, lightColor: .black) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(menuItems, id: \.id) { item in
                    HStack(alignment: .center, spacing: 16) {
                        if let icon = item.icon {
                            GlacierImage(
                                name: .constant(icon),
                                width: 20,
                                height: 20,
                                shouldAdaptToColorSchemeChange: false,
                                customTintColor: $forgroundColor
                            )
                        }
                        
                        if let title = item.title {
                            GlacierLabel(
                                text: title,
                                font: .bodyThick,
                                customTextColor: $forgroundColor
                            )
                        }
                    }
                    .onTapGesture {
                        item.action()
                    }
                }
            }
        }
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        forgroundColor = scheme == .dark ? .black : .white
    }
}

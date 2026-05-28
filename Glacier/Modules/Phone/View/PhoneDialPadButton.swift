//
//  PhoneDialPadButton.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 25/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneDialPadButton draws UI for individula digits.
 */
struct PhoneDialPadButton: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    
    @State private var isAppearing = false
    @State private var backgroundColor: Color = .grey30
    @State private var didLongPress: Bool = false
    
    private let title: String?
    private let icon: String?
    private let diameter: CGFloat
    private let titleFontSize: CGFloat
    private let subTitle: String?
    private let subTitleFontSize: CGFloat
    private let spaceBWTitleAndSubTitle: CGFloat
    private let action: () -> Void
    private var longPressAction: (() -> Void)? = nil

    // MARK: - Initializer

    init(
        icon: String? = nil,
        title: String? = nil,
        subTitle: String? = nil,
        diameter: CGFloat = 74,
        titleFontSize: CGFloat = 34,
        subTitleFontSize: CGFloat = 10,
        spaceBWTitleAndSubTitle: CGFloat = 2,
        action: @escaping () -> Void,
        longPressAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subTitle = subTitle
        self.diameter = diameter
        self.titleFontSize = titleFontSize
        self.subTitleFontSize = subTitleFontSize
        self.spaceBWTitleAndSubTitle = spaceBWTitleAndSubTitle
        self.action = action
        self.longPressAction = longPressAction
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        Button(
            action: {
                guard !didLongPress else { return }
                action()
            },
            label: {
                ZStack(alignment: .center) {
                    Circle()
                        .fill(backgroundColor)
                        .frame(width: diameter, height: diameter)
                    
                    VStack(alignment: .center, spacing: spaceBWTitleAndSubTitle) {
                        if let titleText = title {
                            GlacierLabel(
                                text: titleText,
                                font: .neueHassGroteskFont(ofSize: titleFontSize)
                            )
                        } else if let iconName = icon {
                            GlacierImage(
                                name: .constant(iconName),
                                width: 20,
                                height: 20,
                                shouldAdaptToColorSchemeChange: true
                            )
                        }
                        
                        if let subTitleText = subTitle {
                            GlacierLabel(
                                text: subTitleText,
                                font: .neueHassGroteskThickFont(ofSize: subTitleFontSize)
                            )
                        }
                    }
                }
            }
        )
        .buttonStyle(DialButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                self.didLongPress = true
                self.longPressAction?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.didLongPress = false
                }
            }
        )
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
        backgroundColor = scheme == .dark ? .grey70 : .grey30
    }
}

struct DialButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}


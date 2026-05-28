//
//  PopupConfiguration.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 PopupConfiguration encapsulates properties (title, description, buttons, button action handlders, etc.) for the prompt views that need to be presented over the root screen.
 */
struct PopupConfiguration: Identifiable {
    let id: String = UUID().uuidString
    
    let title: String?
    let description: String?
    let descriptionAlignment: Alignment
    let inputTextConfiguration: PopupInputTextConfiguration?
    let buttonsAlignment: PopupButtonAlignment
    let buttons: [PopupButton]
    
    init(
        title: String? = nil,
        description: String? = nil,
        descriptionAlignment: Alignment = .center,
        inputTextConfiguration: PopupInputTextConfiguration? = nil,
        buttons: [PopupButton],
        buttonsAlignment: PopupButtonAlignment = .horizontal
    ) {
        self.title = title
        self.description = description
        self.descriptionAlignment = descriptionAlignment
        self.inputTextConfiguration = inputTextConfiguration
        self.buttonsAlignment = buttonsAlignment
        self.buttons = buttons
    }
}

struct PopupInputTextConfiguration: Identifiable {
    let id: String = UUID().uuidString
    
    let placeholder: String?
    let onInputTextChange: (String) -> Void
    
    init(
        placeholder: String? = nil,
        onInputTextChange: @escaping (String) -> Void
    ) {
        self.placeholder = placeholder
        self.onInputTextChange = onInputTextChange
    }
}

enum PopupButtonAlignment: Identifiable {
    case horizontal, vertical
    var id: Self { return self }
}

struct PopupButton: Identifiable {
    let id: String = UUID().uuidString
    
    let style: GlacierButtonSyle
    let title: String
    let titleColor: Color?
    let onTap: () -> Void
    
    init(
        style: GlacierButtonSyle = .primary,
        title: String = "",
        titleColor: Color? = nil,
        onTap: @escaping (() -> Void)
    ) {
        self.style = style
        self.title = title
        self.titleColor = titleColor
        self.onTap = onTap
    }
}

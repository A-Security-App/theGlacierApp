//
//  GlacierTextField.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 `GlacierTextFieldState` defines states for the `GlacierTextField` componenet.
 */
enum GlacierTextFieldState: Identifiable {
    case idle, active, error
    
    var id: Self { return self }
    var borderColor: Color {
        switch self {
        case .idle: return .grey20
        case .active: return .black
        case .error: return .ember
        }
    }
}

/**
 `GlacierTextField` provides common UI/UX and functionality for textfield element.
 It is highly configurable like getting real time updated text, showing placeholder, showing error feedback, displaying it as secured text field, setting custom color, etc.
 */
struct GlacierTextField: View {
    
    // MARK: - Private properties
    
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var isSecuredTextFieldFocused: Bool
    
    @Binding private var text: String
    @Binding private var error: String?
    @Binding private var state: GlacierTextFieldState
    
    @State private var backgroundColor: Color = .white
    @State private var borderColor: Color = .grey20
    @State private var shouldShowTextField: Bool = false
    @State private var shouldHideSecuredText = true
    
    private var width: CGFloat
    private var height: CGFloat
    private var cornerRadius: CGFloat
    private var placeholder: String
    private var isSecured: Bool
    private var onSubmit: (() -> Void)?
    
    // MARK: - Initializer
    
    init(
        width: CGFloat = CGFloat.infinity,
        height: CGFloat = 72,
        cornerRadius: CGFloat = 16,
        placeholder: String,
        isSecured: Bool = false,
        text: Binding<String>,
        error: Binding<String?> = .constant(nil),
        state: Binding<GlacierTextFieldState> = .constant(.idle),
        onSubmit: (() -> Void)? = nil
    ) {
        
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
        self.isSecured = isSecured
        self.onSubmit = onSubmit
        self._text = text
        self._error = error
        self._state = state
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)
                    .frame(maxWidth: width)
                    .frame(height: height)
                    .onTapGesture {
                        withAnimation(.easeIn(duration: 0.2)) {
                            if state != .error {
                                state = .active
                                borderColor = GlacierTextFieldState.active.borderColor
                            }
                            shouldShowTextField = true
                        }
                        
                        isSecuredTextFieldFocused = isSecured
                        isTextFieldFocused = !isSecured
                    }
                
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(lineWidth: 1)
                    .stroke(borderColor)
                    .frame(maxWidth: width)
                    .frame(height: height)
                
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        GlacierLabel(
                            text: placeholder,
                            font: .bodyRegular,
                            textAlignment: .leading,
                            customTextColor: .constant(.grey50)
                        )
                        .frame(height: 20)
                        
                        if shouldShowTextField {
                            HStack(alignment: .center){
                                ZStack {
                                    SecureField("", text: $text)
                                        .multilineTextAlignment(.leading)
                                        .font(.bodyRegular)
                                        .foregroundColor(.black)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                        .focused($isSecuredTextFieldFocused)
                                        .frame(height: 20)
                                        .opacity(isSecured && shouldHideSecuredText ? 1 : 0)
                                        .onSubmit {
                                            onSubmit?()
                                        }
                                    
                                    TextField("", text: $text)
                                        .multilineTextAlignment(.leading)
                                        .font(.bodyRegular)
                                        .foregroundColor(.black)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                        .focused($isTextFieldFocused)
                                        .frame(height: 20)
                                        .opacity(!isSecured || !shouldHideSecuredText ? 1 : 0)
                                        .onSubmit {
                                            onSubmit?()
                                        }
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if isSecured && !text.isEmpty {
                        Button {
                            shouldHideSecuredText.toggle()
                            DispatchQueue.main.async {
                                if isSecuredTextFieldFocused {
                                    isSecuredTextFieldFocused = isSecured
                                }
                            }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(backgroundColor)
                                    .frame(width: 40, height: 40)
                                
                                GlacierImage(
                                    name: .constant(shouldHideSecuredText ? "eye-open-icon" : "eye-closed-icon"),
                                    width: 25,
                                    height: 25
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            
            if let error = error {
                GlacierLabel(text: error, font: .bodyThick, customTextColor: .constant(.ember))
                    .padding(.horizontal, 18)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                shouldShowTextField = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            setFocused(for: self.state)
        }
        .onChange(of: state) { state in
            borderColor = state.borderColor
            setFocused(for: state)
        }
        .onChange(of: isTextFieldFocused) { focused in
            setStateOnFocusStateChange(isFocused: focused)
        }
        .onChange(of: isSecuredTextFieldFocused) { focused in
            setStateOnFocusStateChange(isFocused: focused)
        }
        .onChange(of: error ??  "") { error in
            guard !error.isEmpty else { return }
            state = .error
        }
    }
    
    // MARK: - Private methods
    
    private func setStateOnFocusStateChange(isFocused: Bool) {
        guard !isFocused else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            let hasEmptyText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            shouldShowTextField = !hasEmptyText
            if state != .error {
                state = hasEmptyText ? .idle : .active
            }
        }
    }
    
    private func setFocused(for state: GlacierTextFieldState) {
        let isActive = state == .active
        
        shouldShowTextField = isActive
        isSecuredTextFieldFocused = isSecured && isActive
        isTextFieldFocused = !isSecured && isActive
    }
}
